//
//  DeploymentActivityStore.swift
//  Arcane Mobile
//
//  App-level owner of the (single) running deploy/redeploy/pull/build
//  operation. Lifting the stream out of the presenting sheet lets the sheet be
//  dismissed mid-run: the floating DeploymentPill and the Live Activity keep
//  showing progress, and completion side-effects (cache invalidation,
//  mutation-store bump, haptics, toast) fire regardless of what's on screen.
//
//  The operation is backed by a server-side Activity: the backend detaches
//  jobs from the HTTP request lifecycle and records status/step/progress/
//  output. If the local NDJSON stream drops (suspension, network), the store
//  re-attaches by polling that activity until it lands, and Cancel cancels
//  server-side — the local stream is a live view, not the source of truth.
//
//  v1 supports one operation at a time — starting a second is refused with an
//  info toast rather than queued.
//

import SwiftUI
import UIKit
import Arcane

// MARK: - Action kind

enum DeploymentActionKind: String, Sendable {
    case up, redeploy, pull, build, containerRedeploy, imagePull, containerUpdate

    var verb: String {
        switch self {
        case .up: "Deploy"
        case .redeploy, .containerRedeploy: "Redeploy"
        case .pull: "Pull Images"
        case .build: "Build Images"
        case .imagePull: "Pull"
        case .containerUpdate: "Update"
        }
    }

    var systemImage: String {
        switch self {
        case .up: "shippingbox.fill"
        case .redeploy, .containerRedeploy: "arrow.triangle.2.circlepath"
        case .pull, .imagePull: "arrow.down"
        case .build: "hammer.fill"
        case .containerUpdate: "arrow.up.circle.fill"
        }
    }

    /// Kinds backed by plain request/response calls rather than an NDJSON
    /// stream — pill + Live Activity only, and the response is authoritative.
    var isRequestBacked: Bool {
        self == .containerRedeploy || self == .containerUpdate
    }
}

// MARK: - Operation

@MainActor
@Observable
final class DeploymentOperation: Identifiable {
    /// One container a `.containerUpdate` operation applies to.
    struct UpdateTarget: Sendable, Hashable {
        let id: String
        let name: String
    }

    let id = UUID()
    let kind: DeploymentActionKind
    let envID: EnvironmentID
    /// Project ID, container ID for `.containerRedeploy`, or the full image
    /// reference ("nginx:latest") for `.imagePull`.
    let targetID: String
    let targetName: String
    let environmentName: String
    /// Containers a `.containerUpdate` runs over (one entry per container,
    /// updated sequentially). Empty for every other kind.
    let updateTargets: [UpdateTarget]
    let startedAt = Date()

    fileprivate(set) var lines: [InstallStreamLine] = []
    fileprivate(set) var status: InstallStreamStatus = .running
    fileprivate(set) var currentPhase: String?
    fileprivate(set) var seenPhases: [String] = []
    /// 0…1 for image pulls once layer totals are known; nil = indeterminate.
    fileprivate(set) var progressFraction: Double?
    /// The server-side Activity backing this operation. Every deploy/pull/etc.
    /// is recorded by the backend independently of the HTTP stream, which is
    /// what lets the app re-attach after a disconnect and cancel server-side.
    fileprivate(set) var serverActivityID: String?
    /// True once the local stream has dropped and progress is being followed
    /// from the server activity instead.
    fileprivate(set) var isServerSynced = false

    /// Per-layer pull progress keyed by layer digest, used to derive
    /// `progressFraction`. Compose up/redeploy/build emit no totals and stay
    /// indeterminate.
    @ObservationIgnored fileprivate var pullLayers: [String: (current: Int64, total: Int64)] = [:]
    /// Server activity messages already appended (or deliberately skipped),
    /// so re-attach polling never duplicates lines.
    @ObservationIgnored fileprivate var syncedMessageIDs: Set<String> = []
    /// Messages older than this were (approximately) already shown by the live
    /// stream before it dropped — they're skipped during backfill.
    @ObservationIgnored fileprivate var serverSyncCursor: Date?

    init(kind: DeploymentActionKind, envID: EnvironmentID, targetID: String,
         targetName: String, environmentName: String,
         updateTargets: [UpdateTarget] = []) {
        self.kind = kind
        self.envID = envID
        self.targetID = targetID
        self.targetName = targetName
        self.environmentName = environmentName
        self.updateTargets = updateTargets
    }

    /// Sheet/pill title, mirroring the pre-store sheet titles: name-scoped for
    /// deploy/redeploy, plain for pull/build.
    var title: String {
        switch kind {
        case .pull, .build: kind.verb
        default: "\(kind.verb) \(targetName)"
        }
    }
}

// MARK: - Store

@MainActor
@Observable
final class DeploymentActivityStore {
    static let shared = DeploymentActivityStore()
    private init() {}

    /// The active or just-finished operation. Terminal operations linger until
    /// acknowledged (Done button) or auto-cleared shortly after finishing with
    /// the sheet closed, so the pill can show a brief success/failure state.
    private(set) var operation: DeploymentOperation?

    /// Drives the root-level stream sheet. Setting it false with a terminal
    /// operation schedules the pill's auto-clear.
    var isSheetPresented = false {
        didSet {
            if !isSheetPresented, let operation, operation.status.isTerminal {
                scheduleAutoClear(for: operation)
            }
        }
    }

    var isRunning: Bool { operation.map { !$0.status.isTerminal } ?? false }

    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var resolverTask: Task<Void, Never>?
    @ObservationIgnored private var resumeProbeTask: Task<Void, Never>?
    @ObservationIgnored private var autoClearTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private let liveActivity = DeployLiveActivityController()
    /// Client captured at `start()` so cancel/re-sync outlive view contexts.
    @ObservationIgnored private var activeClient: ArcaneClient?
    /// Manager + mutation store captured at `start()` so the resume probe can
    /// run completion side-effects without a view context.
    @ObservationIgnored private var activeManager: ArcaneClientManager?
    @ObservationIgnored private var activeMutationStore: ResourceMutationStore?
    /// Distinguishes the user's Cancel from transport drops: only the former
    /// should end the operation — drops re-attach to the server activity.
    @ObservationIgnored private var userCancelRequested = false
    /// v1 servers don't expose the activities API — without it there's nothing
    /// to re-attach to and the store falls back to stream-only behavior.
    @ObservationIgnored private var serverSyncSupported = false

    private static let maxLines = 2000
    private static let lineTrim = 200
    private static let terminalPillLinger: Duration = .seconds(4)

    // MARK: Lifecycle

    /// Starts an operation. Returns false (with an info toast) when another
    /// operation is already running, or when no client is configured.
    @discardableResult
    func start(kind: DeploymentActionKind,
               envID: EnvironmentID,
               targetID: String,
               targetName: String,
               environmentName: String,
               manager: ArcaneClientManager,
               mutationStore: ResourceMutationStore,
               updateTargets: [DeploymentOperation.UpdateTarget] = [],
               presentSheet: Bool? = nil) -> Bool {
        guard !isRunning else {
            showToast(.info("Another deployment is running"))
            return false
        }
        guard let client = manager.client else { return false }

        autoClearTask?.cancel()
        autoClearTask = nil
        userCancelRequested = false
        activeClient = client
        activeManager = manager
        activeMutationStore = mutationStore
        serverSyncSupported = manager.serverCapabilities?.supportsActivities == true

        let operation = DeploymentOperation(
            kind: kind, envID: envID, targetID: targetID,
            targetName: targetName, environmentName: environmentName,
            updateTargets: updateTargets
        )
        self.operation = operation
        // Request-backed kinds (container redeploy/update) have no stream
        // worth watching — pill + Live Activity only; the sheet stays
        // available via the pill. Callers can override (e.g. image pull
        // starts from its own sheet, so presenting ours mid-dismissal would
        // race).
        isSheetPresented = presentSheet ?? !kind.isRequestBacked
        liveActivity.start(for: operation)

        // Resolve the backing server activity eagerly so a later Cancel or
        // stream drop already knows what to target.
        if serverSyncSupported {
            resolverTask = Task { [weak self] in
                _ = await self?.resolveServerActivity(for: operation, client: client)
            }
        }

        streamTask = Task { [weak self] in
            await self?.run(operation, client: client, manager: manager, mutationStore: mutationStore)
        }
        return true
    }

    /// Cancels the operation — server-side too, since the backend detaches the
    /// job from the HTTP stream and would otherwise keep going.
    func cancel() {
        guard isRunning, let operation else { return }
        userCancelRequested = true
        if serverSyncSupported, let client = activeClient {
            let envID = operation.envID
            Task { [weak self] in
                // The activity ID may still be resolving — give it a moment.
                if let activityID = await self?.awaitServerActivityID(for: operation) {
                    _ = try? await client.activities.cancel(envID: envID, activityID: activityID)
                }
            }
        }
        streamTask?.cancel()
    }

    /// Clears a terminal operation (Done button, pill dismiss, auto-clear).
    func acknowledge() {
        guard operation?.status.isTerminal == true else { return }
        autoClearTask?.cancel()
        autoClearTask = nil
        resolverTask?.cancel()
        resolverTask = nil
        resumeProbeTask?.cancel()
        resumeProbeTask = nil
        activeClient = nil
        activeManager = nil
        activeMutationStore = nil
        operation = nil
        isSheetPresented = false
    }

    /// Buys the stream the ~30s background grace period so short operations
    /// finish and end their Live Activity cleanly. If a stream outlives it,
    /// the drop is caught on resume and the operation re-attaches to its
    /// server activity; the Live Activity's staleDate dims it while suspended.
    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background where isRunning:
            beginBackgroundTask()
        case .active:
            endBackgroundTask()
            probeServerStateAfterResume()
        default:
            break
        }
    }

    /// After a suspension, the frozen stream can take a transport timeout to
    /// error out — meanwhile the pill and Live Activity sit on stale state
    /// even though the operation may have finished server-side. Ask the
    /// server directly on foreground; if the activity already landed, cut the
    /// dead stream loose so the normal re-attach path completes right away.
    private func probeServerStateAfterResume() {
        guard isRunning, serverSyncSupported,
              let operation, !operation.isServerSynced,
              let client = activeClient,
              let activityID = operation.serverActivityID else { return }
        resumeProbeTask?.cancel()
        resumeProbeTask = Task { [weak self] in
            guard let detail = try? await client.activities.detail(
                envID: operation.envID, activityID: activityID, limit: 1
            ) else { return }
            guard let self, !Task.isCancelled,
                  self.operation?.id == operation.id,
                  !operation.status.isTerminal else { return }
            switch detail.activity.status {
            case .success, .failed, .cancelled:
                // Finished while we were suspended. The dead stream task can't
                // host the re-attach (cancelling it would cancel the follow
                // loop too) — kill it and adopt the outcome in a fresh task.
                self.streamTask?.cancel()
                guard let manager = self.activeManager,
                      let mutationStore = self.activeMutationStore else { return }
                self.streamTask = Task { [weak self] in
                    await self?.followServerActivity(
                        operation, activityID: activityID, client: client,
                        manager: manager, mutationStore: mutationStore,
                        transportError: nil
                    )
                }
            case .queued, .running, .unknown(_):
                break
            }
        }
    }

    // MARK: Stream

    private func run(_ operation: DeploymentOperation,
                     client: ArcaneClient,
                     manager: ArcaneClientManager,
                     mutationStore: ResourceMutationStore) async {
        do {
            if operation.kind == .containerRedeploy {
                try await runContainerRedeploy(operation, client: client)
            } else if operation.kind == .containerUpdate {
                // Per-target POSTs with partial-failure reporting; each
                // response is authoritative, so this path terminates the
                // operation itself instead of falling through.
                await runContainerUpdate(operation, client: client,
                                         manager: manager, mutationStore: mutationStore)
                streamTask = nil
                endBackgroundTask()
                return
            } else {
                let stream = try makeStream(for: operation, client: client)
                for try await event in stream {
                    ingest(event, into: operation)
                }
            }
            // Session teardown (logout / demo end) clears the operation while
            // this task unwinds — don't resurrect it with completion effects.
            // The resume probe may also have already landed the outcome.
            guard self.operation?.id == operation.id, !operation.status.isTerminal else { return }
            // A stream can end cleanly even when the operation failed (the
            // server writes an error line, then closes) — the activity record
            // is the authoritative outcome. Container redeploy's POST response
            // already is authoritative.
            if operation.kind != .containerRedeploy,
               let failure = await confirmedServerFailure(for: operation, client: client) {
                guard self.operation?.id == operation.id else { return }
                markFailed(failure, operation: operation)
            } else {
                guard self.operation?.id == operation.id else { return }
                withAnimation(Motion.state) {
                    operation.status = .success
                    operation.currentPhase = "Complete"
                }
                await completeSuccessfully(operation, manager: manager, mutationStore: mutationStore)
            }
        } catch {
            guard self.operation?.id == operation.id, !operation.status.isTerminal else { return }
            if userCancelRequested {
                markFailed("Cancelled", operation: operation)
            } else if serverSyncSupported,
                      // Returns the already-resolved ID immediately when the
                      // eager resolver got there first.
                      let activityID = await resolveServerActivity(for: operation, client: client) {
                // The stream died but the server-side operation continues (the
                // backend detaches jobs from the request lifecycle) — follow
                // the activity record until it lands.
                await followServerActivity(
                    operation, activityID: activityID, client: client,
                    manager: manager, mutationStore: mutationStore,
                    transportError: error
                )
            } else {
                markFailed(friendlyErrorMessage(error), operation: operation)
            }
        }
        streamTask = nil
        endBackgroundTask()
    }

    /// Shared failure path: log line, terminal state, haptic, toast-if-hidden.
    private func markFailed(_ message: String, operation: DeploymentOperation) {
        append(text: message, isError: true, to: operation)
        withAnimation(Motion.state) {
            operation.status = .failure(message)
            operation.currentPhase = message == "Cancelled" ? "Cancelled" : "Failed"
        }
        HapticsManager.warning()
        if !isSheetPresented {
            let cancelled = message == "Cancelled"
            let title = cancelled
                ? "\(operation.title) cancelled"
                : "\(operation.title) failed: \(message)"
            // "View" opens the full log so the complete error is reachable —
            // the toast itself only fits a couple of lines.
            showToast(Toast(
                title: title,
                duration: 5,
                symbol: "exclamationmark.triangle.fill",
                symbolTint: .red,
                actionTitle: "View",
                haptic: .error,
                action: { [weak self] in
                    guard let self, self.operation != nil else { return true }
                    self.isSheetPresented = true
                    return true
                }
            ))
        }
        finishPresentation(for: operation)
    }

    private func makeStream(for operation: DeploymentOperation,
                            client: ArcaneClient) throws -> NDJSONStream<PullProgressEvent> {
        switch operation.kind {
        case .up:
            try client.projects.deployStream(envID: operation.envID, projectID: operation.targetID)
        case .redeploy:
            client.projects.redeployStream(envID: operation.envID, projectID: operation.targetID)
        case .pull:
            try client.projects.pullImagesStream(envID: operation.envID, projectID: operation.targetID)
        case .build:
            try client.projects.buildStream(envID: operation.envID, projectID: operation.targetID)
        case .imagePull:
            try {
                let (image, tag) = Self.parseImageNameAndTag(operation.targetID)
                return try client.images.pullStream(
                    envID: operation.envID,
                    options: ImagePullOptions(imageName: image, tag: tag)
                )
            }()
        case .containerRedeploy, .containerUpdate:
            preconditionFailure("\(operation.kind.rawValue) is not stream-backed")
        }
    }

    /// Splits "registry:5000/nginx:1.27@sha256:…" into name + optional tag,
    /// stripping any digest. (Moved from the old PullImageView.)
    static func parseImageNameAndTag(_ raw: String) -> (String, String?) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let beforeDigest = trimmed.split(separator: "@", maxSplits: 1).first.map(String.init) ?? trimmed
        // The last ':' is a tag separator only when nothing after it contains
        // '/' (otherwise it's the registry host:port).
        if let colonIdx = beforeDigest.lastIndex(of: ":"),
           !beforeDigest[colonIdx...].contains("/") {
            let name = String(beforeDigest[..<colonIdx])
            let tag = String(beforeDigest[beforeDigest.index(after: colonIdx)...])
            return (name, tag.isEmpty ? nil : tag)
        }
        return (beforeDigest, nil)
    }

    private func runContainerRedeploy(_ operation: DeploymentOperation,
                                      client: ArcaneClient) async throws {
        append(text: "Requesting redeploy…", isError: false, to: operation)
        updatePhase("Redeploying", on: operation)
        let path = client.rest.environmentPath(operation.envID, "containers/\(operation.targetID)/redeploy")
        let _: ContainerSummary = try await client.rest.post(path, body: String?.none)
        append(text: "Container recreated", isError: false, to: operation)
    }

    /// Updates each target container sequentially through the per-container
    /// updater endpoint (pull latest image + recreate; the server handles
    /// compose containers via their project). Each POST response is
    /// authoritative, so success/failure is decided here — no server
    /// re-attach.
    private func runContainerUpdate(_ operation: DeploymentOperation,
                                    client: ArcaneClient,
                                    manager: ArcaneClientManager,
                                    mutationStore: ResourceMutationStore) async {
        let targets = operation.updateTargets
        var failures: [String] = []

        for (index, target) in targets.enumerated() {
            guard self.operation?.id == operation.id, !Task.isCancelled else { return }
            updatePhase(targets.count == 1 ? "Updating" : "Updating \(target.name)", on: operation)
            append(text: "Updating \(target.name)…", isError: false, to: operation)
            liveActivity.update(for: operation, immediate: false)
            do {
                let result = try await client.updater.updateContainer(target.id, envID: operation.envID)
                ingest(result, into: operation)
                failures.append(contentsOf: failureMessages(in: result))
            } catch {
                let message = friendlyErrorMessage(error)
                append(text: "\(target.name): \(message)", isError: true, to: operation)
                failures.append("\(target.name): \(message)")
            }
            if targets.count > 1 {
                operation.progressFraction = Double(index + 1) / Double(targets.count)
            }
            liveActivity.update(for: operation, immediate: false)
        }

        guard self.operation?.id == operation.id, !operation.status.isTerminal else { return }
        if userCancelRequested {
            markFailed("Cancelled", operation: operation)
        } else if let first = failures.first {
            let message = failures.count > 1 ? "\(first) (+\(failures.count - 1) more)" : first
            markFailed(message, operation: operation)
        } else {
            withAnimation(Motion.state) {
                operation.status = .success
                operation.currentPhase = "Complete"
            }
            await completeSuccessfully(operation, manager: manager, mutationStore: mutationStore)
        }
    }

    /// Renders an updater result's per-resource items as log lines.
    private func ingest(_ result: UpdaterResult, into operation: DeploymentOperation) {
        for item in result.items {
            let name = item.resourceName ?? item.resourceId
            if let error = item.error, !error.isEmpty {
                append(text: "\(name): \(error)", isError: true, to: operation)
                continue
            }
            var line = "\(name): \(Self.updaterStatusLabel(item.status))"
            if let change = Self.updaterImageChange(item) {
                line += " · \(change)"
            }
            append(text: line, isError: false, to: operation)
        }
    }

    private func failureMessages(in result: UpdaterResult) -> [String] {
        result.items.compactMap { item in
            guard let error = item.error, !error.isEmpty else { return nil }
            return "\(item.resourceName ?? item.resourceId): \(error)"
        }
    }

    private static func updaterStatusLabel(_ status: String) -> String {
        switch status.lowercased() {
        case "updated": "updated"
        case "up_to_date": "already up to date"
        case "restarted": "restarted"
        case "skipped": "skipped"
        case "checked": "checked"
        case "failed": "failed"
        default: status
        }
    }

    private static func updaterImageChange(_ item: UpdaterResourceResult) -> String? {
        let old = item.oldImages ?? [:]
        let new = item.newImages ?? [:]
        guard let key = new.keys.first ?? old.keys.first else { return nil }
        switch (old[key], new[key]) {
        case let (.some(from), .some(to)) where from != to: return "\(from) → \(to)"
        case let (_, .some(to)): return to
        case let (.some(from), _): return from
        default: return nil
        }
    }

    private func ingest(_ event: PullProgressEvent, into operation: DeploymentOperation) {
        let isError = event.error != nil
        let display = displayText(for: event)
        if !display.isEmpty {
            append(text: display, isError: isError, to: operation)
        }
        if !isError {
            if let phase = event.status?.trimmingCharacters(in: .whitespacesAndNewlines),
               !phase.isEmpty {
                updatePhase(phase, on: operation)
            }
            updateProgress(from: event, on: operation)
        }
        // Throttled inside the controller — interleaved per-layer statuses can
        // flip the phase many times a second, so even phase changes ride the
        // coalesced update rather than forcing immediate ActivityKit calls.
        liveActivity.update(for: operation, immediate: false)
    }

    // MARK: Event formatting (ported from StreamingActionView)

    private func displayText(for event: PullProgressEvent) -> String {
        if let error = event.error { return "Error: \(error)" }
        if let stream = event.stream {
            let trimmed = stream.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        var parts: [String] = []
        if let status = event.status, !status.isEmpty { parts.append(status) }
        if let id = event.id, !id.isEmpty, parts.isEmpty {
            parts.append("layer \(String(id.prefix(12)))")
        }
        if let progress = event.progress, !progress.isEmpty { parts.append(progress) }
        return parts.joined(separator: " ")
    }

    private func append(text: String, isError: Bool, to operation: DeploymentOperation) {
        operation.lines.append(InstallStreamLine(text: text, isError: isError))
        if operation.lines.count > Self.maxLines {
            operation.lines.removeFirst(Self.lineTrim)
        }
    }

    private func updatePhase(_ phase: String, on operation: DeploymentOperation) {
        guard phase != operation.currentPhase else { return }
        withAnimation(Motion.state) {
            operation.currentPhase = phase
            if !operation.seenPhases.contains(phase) {
                operation.seenPhases.append(phase)
            }
        }
    }

    // MARK: Pull progress

    /// Statuses Docker emits when a layer needs no further download work.
    private static let layerDoneStatuses: Set<String> = [
        "Pull complete", "Already exists", "Download complete"
    ]

    private func updateProgress(from event: PullProgressEvent, on operation: DeploymentOperation) {
        guard let layerID = event.id, !layerID.isEmpty else { return }
        if let detail = event.progressDetail, let total = detail.total, total > 0 {
            operation.pullLayers[layerID] = (current: min(detail.current ?? 0, total), total: total)
        } else if let status = event.status, Self.layerDoneStatuses.contains(status),
                  let known = operation.pullLayers[layerID] {
            operation.pullLayers[layerID] = (current: known.total, total: known.total)
        }

        let totals = operation.pullLayers.values.reduce(into: (current: Int64(0), total: Int64(0))) {
            $0.current += $1.current
            $0.total += $1.total
        }
        guard totals.total > 0 else { return }
        let fraction = min(Double(totals.current) / Double(totals.total), 1)
        // Monotonic: new layers registering mid-pull grow the denominator, which
        // would otherwise make the bar jump backwards.
        if fraction > (operation.progressFraction ?? 0) {
            operation.progressFraction = fraction
        }
    }

    // MARK: Server activity sync

    private static func activityType(for kind: DeploymentActionKind) -> ActivityType {
        switch kind {
        case .up: .projectDeploy
        case .redeploy: .projectRedeploy
        case .pull: .projectPull
        case .build: .projectBuild
        case .containerRedeploy: .containerRedeploy
        case .imagePull: .imagePull
        case .containerUpdate: .autoUpdate
        }
    }

    /// Finds the server Activity created for this operation. The streaming
    /// endpoints emit the activity ID as their first NDJSON line, but the
    /// SDK's typed stream drops it — so correlate by type + resource + start
    /// time instead. Retries briefly since the row is created as the request
    /// starts.
    private func resolveServerActivity(for operation: DeploymentOperation,
                                       client: ArcaneClient) async -> String? {
        if let id = operation.serverActivityID { return id }
        let type = Self.activityType(for: operation.kind)
        let earliest = operation.startedAt.addingTimeInterval(-60)
        for attempt in 1...6 {
            guard !Task.isCancelled, self.operation?.id == operation.id else { return nil }
            if let id = operation.serverActivityID { return id }
            do {
                let page = try await client.activities.listPaginated(
                    envID: operation.envID, limit: 20, type: type
                )
                // Image pulls carry an empty resourceID and identify the image
                // via resourceName; everything else matches on resourceID. The
                // prefix check tolerates the backend appending a default tag
                // ("nginx" → "nginx:latest").
                let target = operation.targetID
                let match = page.data
                    .filter { activity in
                        (activity.resourceID == target
                            || activity.resourceName == target
                            || (activity.resourceName?.hasPrefix(target + ":") ?? false))
                            && activity.startedAt >= earliest
                    }
                    .max { $0.startedAt < $1.startedAt }
                if let match {
                    operation.serverActivityID = match.id
                    return match.id
                }
            } catch {
                // Transient — retry below.
            }
            try? await Task.sleep(for: .milliseconds(400 * attempt))
        }
        return nil
    }

    /// Checks the activity record after a cleanly-ended stream. Returns a
    /// failure message when the server marked the operation failed/cancelled,
    /// nil when it succeeded or no verdict is available (unresolved activity,
    /// record still flushing) — in which case the stream's view stands.
    private func confirmedServerFailure(for operation: DeploymentOperation,
                                        client: ArcaneClient) async -> String? {
        guard let activityID = operation.serverActivityID else { return nil }
        for _ in 0..<3 {
            if let detail = try? await client.activities.detail(
                envID: operation.envID, activityID: activityID, limit: 1
            ) {
                switch detail.activity.status {
                case .failed: return detail.activity.error ?? "Failed on server"
                case .cancelled: return "Cancelled"
                case .success: return nil
                case .queued, .running, .unknown(_): break // still flushing
                }
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return nil
    }

    /// Waits briefly for the eager resolver before Cancel gives up on a
    /// server-side cancellation.
    private func awaitServerActivityID(for operation: DeploymentOperation) async -> String? {
        for _ in 0..<15 {
            if let id = operation.serverActivityID { return id }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return operation.serverActivityID
    }

    /// Follows the server activity after the local stream drops: polls the
    /// activity detail (status, step, progress, output messages) until it
    /// reaches a terminal state, then runs the normal completion paths. While
    /// the app is suspended this task freezes with the process and simply
    /// resumes polling on return to foreground.
    private func followServerActivity(_ operation: DeploymentOperation,
                                      activityID: String,
                                      client: ArcaneClient,
                                      manager: ArcaneClientManager,
                                      mutationStore: ResourceMutationStore,
                                      transportError: Error?) async {
        operation.isServerSynced = true
        operation.serverSyncCursor = Date().addingTimeInterval(-2)
        append(text: "Stream interrupted — following the server activity…", isError: false, to: operation)
        updatePhase("Reconnecting", on: operation)
        liveActivity.update(for: operation, immediate: true)

        var consecutiveFailures = 0
        while !Task.isCancelled {
            guard self.operation?.id == operation.id else { return }
            do {
                let detail = try await client.activities.detail(
                    envID: operation.envID, activityID: activityID, limit: 200
                )
                consecutiveFailures = 0
                apply(detail, to: operation)

                switch detail.activity.status {
                case .success:
                    withAnimation(Motion.state) {
                        operation.status = .success
                        operation.currentPhase = "Complete"
                    }
                    await completeSuccessfully(operation, manager: manager, mutationStore: mutationStore)
                    return
                case .failed:
                    markFailed(detail.activity.error ?? "Failed on server", operation: operation)
                    return
                case .cancelled:
                    markFailed("Cancelled", operation: operation)
                    return
                case .queued, .running, .unknown(_):
                    break
                }
            } catch {
                guard !(error is CancellationError) else { break }
                consecutiveFailures += 1
                if consecutiveFailures >= 8 {
                    markFailed(friendlyErrorMessage(transportError ?? error), operation: operation)
                    return
                }
            }
            try? await Task.sleep(for: .seconds(2))
        }

        // Cancelled while following — the user hit Cancel (server cancel was
        // requested separately) or the session ended.
        guard self.operation?.id == operation.id else { return }
        if userCancelRequested {
            markFailed("Cancelled", operation: operation)
        }
    }

    /// Merges a polled activity snapshot into the operation: backfills output
    /// messages (deduped, skipping ones the live stream already showed), and
    /// adopts the server's step + progress.
    private func apply(_ detail: ActivityDetail, to operation: DeploymentOperation) {
        let cursor = operation.serverSyncCursor ?? .distantPast
        let fresh = detail.messages
            .filter { !operation.syncedMessageIDs.contains($0.id) }
            .sorted { $0.createdAt < $1.createdAt }
        for message in fresh {
            operation.syncedMessageIDs.insert(message.id)
            guard message.createdAt >= cursor else { continue }
            append(text: message.message, isError: message.level == .error, to: operation)
        }

        let step = detail.activity.step.trimmingCharacters(in: .whitespacesAndNewlines)
        if !step.isEmpty {
            updatePhase(step, on: operation)
        }
        if let progress = detail.activity.progress {
            let fraction = min(max(Double(progress) / 100, 0), 1)
            if fraction > (operation.progressFraction ?? 0) {
                operation.progressFraction = fraction
            }
        }
        liveActivity.update(for: operation, immediate: false)
    }

    // MARK: Completion

    private func completeSuccessfully(_ operation: DeploymentOperation,
                                      manager: ArcaneClientManager,
                                      mutationStore: ResourceMutationStore) async {
        await invalidateCaches(for: operation, manager: manager)
        switch operation.kind {
        case .containerRedeploy:
            mutationStore.markChanged(kind: .containers, envID: operation.envID)
        case .imagePull:
            mutationStore.markChanged(kind: .images, envID: operation.envID)
        case .containerUpdate:
            // A new image was pulled and containers were recreated; compose
            // consumers surface project changes too.
            mutationStore.markChanged(kind: .containers, envID: operation.envID)
            mutationStore.markChanged(kind: .images, envID: operation.envID)
            mutationStore.markChanged(kind: .projects, envID: operation.envID)
        default:
            mutationStore.markChanged(kind: .projects, envID: operation.envID)
        }
        HapticsManager.success()
        ReviewPrompter.shared.recordSuccess()
        if !isSheetPresented {
            showToast(.success("\(operation.title) complete"))
        }
        finishPresentation(for: operation)
    }

    private func invalidateCaches(for operation: DeploymentOperation,
                                  manager: ArcaneClientManager) async {
        guard let cached = manager.cached, let client = manager.client else { return }
        let envID = operation.envID
        switch operation.kind {
        case .containerRedeploy:
            await cached.invalidate(envID: envID, paths: [
                client.rest.environmentPath(envID, "containers"),
                client.rest.environmentPath(envID, "containers/*")
            ])
        case .containerUpdate:
            await cached.invalidate(envID: envID, paths: [
                client.rest.environmentPath(envID, "containers"),
                client.rest.environmentPath(envID, "containers/*"),
                client.rest.environmentPath(envID, "images") + "*",
                client.rest.environmentPath(envID, "images/*")
            ])
        case .imagePull:
            await cached.invalidate(envID: envID, paths: [
                client.rest.environmentPath(envID, "images") + "*",
                client.rest.environmentPath(envID, "images/*")
            ])
        default:
            await cached.invalidate(envID: envID, paths: [
                client.rest.environmentPath(envID, "projects") + "*",
                client.rest.environmentPath(envID, "projects/*"),
                client.rest.environmentPath(envID, "containers"),
                client.rest.environmentPath(envID, "containers/*")
            ])
        }
    }

    private func finishPresentation(for operation: DeploymentOperation) {
        liveActivity.end(for: operation)
        if !isSheetPresented {
            scheduleAutoClear(for: operation)
        }
    }

    private func scheduleAutoClear(for operation: DeploymentOperation) {
        autoClearTask?.cancel()
        autoClearTask = Task { [weak self] in
            try? await Task.sleep(for: Self.terminalPillLinger)
            guard !Task.isCancelled, let self else { return }
            // Only clear if this exact operation is still the terminal one and
            // the user hasn't reopened the sheet meanwhile.
            if self.operation?.id == operation.id, !self.isSheetPresented {
                self.acknowledge()
            }
        }
    }

    // MARK: Sign-out

    /// Called when the session ends (logout / demo end): the captured client is
    /// being torn down, so stop the stream and drop the presentation.
    func sessionDidEnd() {
        streamTask?.cancel()
        streamTask = nil
        resolverTask?.cancel()
        resolverTask = nil
        resumeProbeTask?.cancel()
        resumeProbeTask = nil
        autoClearTask?.cancel()
        autoClearTask = nil
        activeClient = nil
        activeManager = nil
        activeMutationStore = nil
        liveActivity.endCurrent()
        operation = nil
        isSheetPresented = false
        endBackgroundTask()
    }

    // MARK: Background task

    private func beginBackgroundTask() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "deployment-stream") { [weak self] in
            Task { @MainActor in self?.endBackgroundTask() }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }
}
