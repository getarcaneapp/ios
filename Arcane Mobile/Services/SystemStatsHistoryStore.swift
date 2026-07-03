import Foundation
import Observation
import Arcane

/// Owns the per-environment `system/stats` streams for the dashboard and
/// retains a rolling sample window per environment, so sparklines survive
/// their card scrolling out of the LazyVStack (card `@State` dies on reuse).
/// Mirrors `DashboardStreamStore`'s lifecycle: `configure(client:)`,
/// `reconcile(environments:)`, `start()`/`stop()` driven by DashboardView's
/// visibility/scenePhase handlers, and a generation counter fencing stale
/// tasks.
@MainActor
@Observable
final class SystemStatsHistoryStore {
    struct Series {
        var cpu: [SparklineSample] = []
        var memory: [SparklineSample] = []
        var latest: SystemStatsFrame?
        var error: String?
    }

    /// Rolling window per series — mirrors `ContainerStatsView.windowSize`.
    static let windowSize = 60
    /// Streams are opened for at most this many environments (dashboard order,
    /// active first) — strictly cheaper than the old per-visible-card streams.
    /// Further cards keep rings-only from whatever data they have.
    static let maxStreams = 6

    /// Reconnect budget/backoff — mirrors `DashboardStreamStore`. A transient
    /// WebSocket handshake failure (e.g. `-1011` bad response during a server
    /// restart or proxy hiccup) no longer permanently kills the stream; the
    /// store backs off and reopens a fresh channel until the budget is spent.
    private static let maxReconnectAttempts = 20
    private static let maxReconnectDelaySeconds: Double = 15
    /// A connection must survive this long before the attempt budget resets —
    /// otherwise a flapping env would reconnect at the base delay forever.
    private static let stableConnectionSeconds: TimeInterval = 5

    private(set) var seriesByEnvironmentID: [String: Series] = [:]

    private var client: ArcaneClient?
    private var clientIdentity: ObjectIdentifier?
    /// Dashboard-ordered enabled environment IDs; the first `maxStreams` get
    /// live streams.
    private var trackedIDs: [String] = []
    private var tasksByEnvironmentID: [String: Task<Void, Never>] = [:]
    /// Bumped on every stop()/start() so frames and errors from a previous
    /// stream generation can't mutate the current one's state.
    private var generation = 0
    private var isRunning = false

    func series(for environmentID: String) -> Series? {
        seriesByEnvironmentID[environmentID]
    }

    // MARK: - Lifecycle

    /// Adopt the manager's client; a different client instance (sign-out/in,
    /// server switch) discards all history.
    func configure(client: ArcaneClient?) {
        let identity = client.map { ObjectIdentifier($0.transport) }
        guard identity != clientIdentity else { return }
        stop()
        clientIdentity = identity
        self.client = client
        seriesByEnvironmentID = [:]
        trackedIDs = []
    }

    /// Track the environments the dashboard shows, in display order. Series
    /// for removed environments are dropped; new ones get a stream if a slot
    /// is free and the store is running.
    func reconcile(environments: [Arcane.Environment]) {
        trackedIDs = environments.filter(\.enabled).map(\.id)
        let target = Set(trackedIDs)
        for id in seriesByEnvironmentID.keys where !target.contains(id) {
            seriesByEnvironmentID.removeValue(forKey: id)
        }
        if isRunning { reconcileTasks() }
    }

    /// Idempotent: live stream tasks are left alone (scenePhase re-entry).
    func start() {
        guard !isRunning else { return }
        isRunning = true
        generation += 1
        reconcileTasks()
    }

    func stop() {
        isRunning = false
        generation += 1
        for task in tasksByEnvironmentID.values { task.cancel() }
        tasksByEnvironmentID = [:]
        // Series are intentionally kept: last-known data keeps rendering.
    }

    // MARK: - Stream tasks

    private var streamedIDs: ArraySlice<String> {
        trackedIDs.prefix(Self.maxStreams)
    }

    private func reconcileTasks() {
        guard isRunning, let client else { return }
        let wanted = Set(streamedIDs)
        for (id, task) in tasksByEnvironmentID where !wanted.contains(id) {
            task.cancel()
            tasksByEnvironmentID.removeValue(forKey: id)
        }
        for id in streamedIDs where tasksByEnvironmentID[id] == nil {
            let generation = generation
            tasksByEnvironmentID[id] = Task { [weak self] in
                await self?.runStream(environmentID: id, client: client, generation: generation)
            }
        }
    }

    private func runStream(environmentID: String, client: ArcaneClient, generation: Int) async {
        // Brief stagger so a dashboard full of cards doesn't open every
        // stream in the same instant (matches the old per-card delay).
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled, generation == self.generation else { return }

        var attempt = 0
        defer {
            if generation == self.generation {
                tasksByEnvironmentID.removeValue(forKey: environmentID)
            }
        }

        // `WebSocketChannel` is single-use: each iteration builds a fresh
        // `statsStream` (and thus a fresh channel) so a dropped/handshake-
        // failed connection is replaced instead of stalling forever.
        while !Task.isCancelled, generation == self.generation {
            let connectedAt = Date()
            var receivedFirstFrame = false
            let stream = client.system.statsStream(envID: EnvironmentID(rawValue: environmentID))
            do {
                for try await frame in stream {
                    guard generation == self.generation, !Task.isCancelled else { return }
                    if !receivedFirstFrame {
                        receivedFirstFrame = true
                        clearError(environmentID: environmentID)
                    }
                    append(frame, environmentID: environmentID)
                }
            } catch is CancellationError {
                return
            } catch {
                guard generation == self.generation, !Task.isCancelled else { return }
                // Keep the last-known series; just flag the error while we
                // back off and try again.
                setError(environmentID: environmentID,
                          "Live stats unavailable: \(friendlyErrorMessage(error))")
            }

            guard generation == self.generation, !Task.isCancelled else { return }

            // A connection that survived past the stable window resets the
            // budget so a one-off blip doesn't eventually exhaust it.
            if receivedFirstFrame, Date().timeIntervalSince(connectedAt) >= Self.stableConnectionSeconds {
                attempt = 0
            }
            if attempt >= Self.maxReconnectAttempts {
                return
            }
            let delay = min(pow(2, Double(attempt)), Self.maxReconnectDelaySeconds)
            attempt += 1
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    private func setError(environmentID: String, _ message: String) {
        var series = seriesByEnvironmentID[environmentID] ?? Series()
        series.error = message
        seriesByEnvironmentID[environmentID] = series
    }

    private func clearError(environmentID: String) {
        guard var series = seriesByEnvironmentID[environmentID], series.error != nil else { return }
        series.error = nil
        seriesByEnvironmentID[environmentID] = series
    }

    private func append(_ frame: SystemStatsFrame, environmentID: String) {
        guard trackedIDs.contains(environmentID) else { return }
        var series = seriesByEnvironmentID[environmentID] ?? Series()
        series.latest = frame
        series.error = nil

        let now = Date()
        series.cpu.append(SparklineSample(timestamp: now, value: clamped(frame.cpuPercent)))
        if let memory = frame.memoryPercent {
            series.memory.append(SparklineSample(timestamp: now, value: clamped(memory)))
        }
        if series.cpu.count > Self.windowSize {
            series.cpu.removeFirst(series.cpu.count - Self.windowSize)
        }
        if series.memory.count > Self.windowSize {
            series.memory.removeFirst(series.memory.count - Self.windowSize)
        }
        seriesByEnvironmentID[environmentID] = series
    }

    private func clamped(_ value: Double) -> Double {
        min(max(value, 0), 100)
    }
}
