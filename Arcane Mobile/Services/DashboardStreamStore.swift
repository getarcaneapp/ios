import Foundation
import Observation
import Arcane

/// Consumes the aggregated `GET /dashboard/stream` NDJSON endpoint (one
/// connection covering the local environment + every enabled remote
/// environment) and tracks per-environment dashboard snapshots, mirroring the
/// web client's dashboard store. Older servers without the endpoint latch
/// `streamUnsupported` after a single 404 and the dashboard silently falls
/// back to the legacy per-environment aggregation.
@MainActor
@Observable
final class DashboardStreamStore {
    struct EnvironmentState: Identifiable {
        let id: String
        var name: String
        var snapshot: DashboardSnapshot?
        /// One-way latch: flips on the first snapshot and never back, so later
        /// errors keep showing the last-known counts instead of skeletons.
        var hasLoaded = false
        var loading = true
        var streamError = false
        var errorMessage: String?
        var errorCode: DashboardStreamErrorCode?
    }

    struct AggregateCounts: Equatable {
        var runningContainers = 0
        var stoppedContainers = 0
        var totalContainers = 0
        var totalImages = 0
    }

    private(set) var statesByEnvironmentID: [String: EnvironmentState] = [:]
    private(set) var connected = false
    /// Set after the reconnect budget is exhausted; cleared by retry().
    private(set) var streamFailed = false
    /// Latched when the server 404s the stream endpoint (predates arcane#2901).
    /// Permanent until configure() sees a different client.
    private(set) var streamUnsupported = false

    private var client: ArcaneClient?
    private var clientIdentity: ObjectIdentifier?
    private var streamTask: Task<Void, Never>?
    /// Bumped on every stop()/start() so events and one-shot fetches from a
    /// previous stream generation can't mutate the current one's state.
    private var generation = 0

    private static let maxReconnectAttempts = 20
    private static let maxReconnectDelaySeconds: Double = 15
    /// A connection must survive this long before the attempt budget resets —
    /// a per-connection poison line would otherwise reconnect at 1s forever.
    private static let stableConnectionSeconds: TimeInterval = 5

    var isStreaming: Bool { streamTask != nil }

    /// Aggregate tile counts across tracked environments. Non-nil only when
    /// every tracked environment has settled (loaded or errored) and at least
    /// one snapshot arrived, so the tiles never dip to a partial sum mid-fill.
    var aggregate: AggregateCounts? {
        guard !statesByEnvironmentID.isEmpty else { return nil }
        var counts = AggregateCounts()
        var loadedCount = 0
        for state in statesByEnvironmentID.values {
            if state.hasLoaded, let snapshot = state.snapshot {
                loadedCount += 1
                counts.runningContainers += snapshot.containers.counts.runningContainers
                counts.stoppedContainers += snapshot.containers.counts.stoppedContainers
                counts.totalContainers += snapshot.containers.counts.totalContainers
                counts.totalImages += snapshot.imageUsageCounts.totalImages
            } else if !state.streamError {
                return nil
            }
        }
        return loadedCount > 0 ? counts : nil
    }

    func state(for environmentID: String) -> EnvironmentState? {
        statesByEnvironmentID[environmentID]
    }

    // MARK: - Lifecycle

    /// Adopt the manager's client; a different client instance (sign-out/in,
    /// server switch) discards all state, including the unsupported latch.
    /// ArcaneClient is a struct, so its transport (one per configured client)
    /// provides the identity.
    func configure(client: ArcaneClient?) {
        let identity = client.map { ObjectIdentifier($0.transport) }
        guard identity != clientIdentity else { return }
        stop()
        clientIdentity = identity
        self.client = client
        statesByEnvironmentID = [:]
        streamUnsupported = false
        streamFailed = false
    }

    /// Idempotent: a live stream task is left alone (scenePhase re-entry).
    func start() {
        guard let client, !streamUnsupported, streamTask == nil else { return }
        generation += 1
        let generation = generation
        streamTask = Task { [weak self] in
            await self?.runStreamLoop(client: client, generation: generation)
        }
    }

    func stop() {
        generation += 1
        streamTask?.cancel()
        streamTask = nil
        connected = false
        streamFailed = false
        // Env states are intentionally kept: last-known data keeps rendering.
    }

    func retry() {
        stop()
        clearAllStreamErrors()
        start()
    }

    // MARK: - Environment tracking

    /// Track the environments the dashboard shows. Only enabled environments
    /// are tracked — the aggregated stream never serves disabled ones, so they
    /// would sit in `loading` forever. Environments added while the stream is
    /// live get a one-shot REST snapshot so they don't wait out the server's
    /// ~30s reconcile tick.
    func reconcile(environments: [Arcane.Environment]) {
        let enabled = environments.filter(\.enabled)
        let targetIDs = Set(enabled.map(\.id))

        for id in statesByEnvironmentID.keys where !targetIDs.contains(id) {
            statesByEnvironmentID.removeValue(forKey: id)
        }

        for environment in enabled {
            let name = environment.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let displayName = name.isEmpty ? environment.id : name
            if var existing = statesByEnvironmentID[environment.id] {
                if existing.name != displayName {
                    existing.name = displayName
                    statesByEnvironmentID[environment.id] = existing
                }
                continue
            }
            statesByEnvironmentID[environment.id] = EnvironmentState(id: environment.id, name: displayName)
            if streamTask != nil {
                let generation = generation
                Task { [weak self] in
                    await self?.refreshEnvironment(environment.id, generation: generation)
                }
            }
        }
    }

    /// Re-fetch every tracked environment's snapshot over REST (pull-to-refresh).
    func refresh() async {
        let generation = generation
        let ids = Array(statesByEnvironmentID.keys)
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { [weak self] in
                    await self?.refreshEnvironment(id, generation: generation)
                }
            }
        }
    }

    // MARK: - Stream loop

    private func runStreamLoop(client: ArcaneClient, generation: Int) async {
        var attempt = 0
        defer {
            if generation == self.generation {
                streamTask = nil
                connected = false
            }
        }

        while !Task.isCancelled, generation == self.generation {
            let connectedAt = Date()
            var receivedFirstEvent = false
            do {
                for try await event in client.dashboard.stream() {
                    guard generation == self.generation, !Task.isCancelled else { return }
                    if !receivedFirstEvent {
                        receivedFirstEvent = true
                        connected = true
                        streamFailed = false
                        // A fresh stream re-emits errors for environments that
                        // are still failing, so stale errors are cleared before
                        // this first event (which may itself be an error) lands.
                        clearAllStreamErrors()
                    }
                    apply(event)
                }
            } catch let error as ArcaneError {
                if case .notFound = error {
                    // Server predates the stream endpoint — silent legacy mode.
                    streamUnsupported = true
                    connected = false
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                // Transport drops, server restarts, schema-mismatch lines
                // (NDJSONStream throws on undecodable JSON) — all retried below.
            }

            connected = false
            guard generation == self.generation, !Task.isCancelled else { return }

            if receivedFirstEvent, Date().timeIntervalSince(connectedAt) >= Self.stableConnectionSeconds {
                attempt = 0
            }
            if attempt >= Self.maxReconnectAttempts {
                streamFailed = true
                return
            }
            let delay = min(pow(2, Double(attempt)), Self.maxReconnectDelaySeconds)
            attempt += 1
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    private func apply(_ event: DashboardStreamEvent) {
        switch event.type {
        case .snapshot:
            guard let snapshot = event.snapshot else { return }
            applySnapshot(snapshot, environmentID: event.resolvedEnvironmentID)
        case .error:
            applyError(
                message: event.error,
                code: event.errorCode,
                environmentID: event.resolvedEnvironmentID
            )
        case .pending, .heartbeat, .unknown:
            break
        }
    }

    private func applySnapshot(_ snapshot: DashboardSnapshot, environmentID: String) {
        // Events can keep arriving briefly for environments removed by
        // reconcile; don't resurrect them.
        guard var state = statesByEnvironmentID[environmentID] else { return }
        state.snapshot = snapshot
        state.hasLoaded = true
        state.loading = false
        state.streamError = false
        state.errorMessage = nil
        state.errorCode = nil
        statesByEnvironmentID[environmentID] = state
    }

    private func applyError(message: String?, code: DashboardStreamErrorCode?, environmentID: String) {
        guard var state = statesByEnvironmentID[environmentID] else { return }
        // Snapshot and hasLoaded stay untouched so last-known data persists.
        state.loading = false
        state.streamError = true
        state.errorMessage = message
        state.errorCode = code
        statesByEnvironmentID[environmentID] = state
    }

    private func clearAllStreamErrors() {
        for (id, var state) in statesByEnvironmentID where state.streamError {
            state.streamError = false
            state.errorMessage = nil
            state.errorCode = nil
            statesByEnvironmentID[id] = state
        }
    }

    private func refreshEnvironment(_ environmentID: String, generation: Int) async {
        guard let client else { return }
        do {
            let snapshot = try await client.dashboard.snapshot(envID: EnvironmentID(rawValue: environmentID))
            guard generation == self.generation, statesByEnvironmentID[environmentID] != nil else { return }
            applySnapshot(snapshot, environmentID: environmentID)
        } catch {
            guard generation == self.generation, statesByEnvironmentID[environmentID] != nil else { return }
            guard !(error is CancellationError) else { return }
            applyError(message: friendlyErrorMessage(error), code: nil, environmentID: environmentID)
        }
    }
}
