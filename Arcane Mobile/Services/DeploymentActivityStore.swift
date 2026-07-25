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
//  The foreground presentation supports one operation at a time — starting a
//  second is refused with an info toast. Activity Center remains the multi-
//  activity view for queued and running server work.
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
    /// Set only by an explicit `done` frame. v2 stream EOF is not success
    /// without this; v1 keeps its legacy clean-EOF behavior.
    @ObservationIgnored fileprivate var receivedTerminalSuccess = false
    /// Resource ID used by the fallback Activity-list resolver. This changes
    /// between targets during a multi-container update.
    @ObservationIgnored fileprivate var activityLookupTargetID: String

    init(kind: DeploymentActionKind, envID: EnvironmentID, targetID: String,
         targetName: String, environmentName: String,
         updateTargets: [UpdateTarget] = []) {
        self.kind = kind
        self.envID = envID
        self.targetID = targetID
        self.targetName = targetName
        self.environmentName = environmentName
        self.updateTargets = updateTargets
        self.activityLookupTargetID = targetID
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
    @ObservationIgnored private var followerTask: Task<Void, Never>?
    @ObservationIgnored private var cancellationTask: Task<Void, Never>?
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
        guard let baseClient = manager.client else { return false }
        let client: ArcaneClient
        do {
            client = try ActivityBatchID.scopedClient(baseClient)
        } catch {
            showToast(.error("Couldn't start operation"))
            return false
        }

        autoClearTask?.cancel()
        autoClearTask = nil
        resolverTask?.cancel()
        resolverTask = nil
        followerTask?.cancel()
        followerTask = nil
        cancellationTask?.cancel()
        cancellationTask = nil
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

        // Stream-backed operations deliver their Activity ID directly. The
        // resolver remains eager only for request-backed operations, whose ID
        // is unavailable until their response arrives.
        if serverSyncSupported, kind.isRequestBacked {
            startActivityResolver(for: operation, client: client)
        }

        streamTask = Task { [weak self] in
            await self?.run(operation, client: client, manager: manager, mutationStore: mutationStore)
        }
        return true
    }

    /// Cancels the operation — server-side too, since the backend detaches the
    /// job from the HTTP stream and would otherwise keep going.
    func cancel() {
        guard isRunning, !userCancelRequested, let operation else { return }
        userCancelRequested = true
        updatePhase("Cancelling", on: operation)
        liveActivity.update(for: operation, immediate: true)

        resolverTask?.cancel()
        resolverTask = nil
        streamTask?.cancel()
        followerTask?.cancel()
        followerTask = nil

        guard serverSyncSupported,
              let client = activeClient,
              let manager = activeManager,
              let mutationStore = activeMutationStore else {
            markFailed("Cancelled", operation: operation)
            return
        }

        cancellationTask?.cancel()
        cancellationTask = Task { [weak self] in
            await self?.cancelServerOperation(
                operation,
                client: client,
                manager: manager,
                mutationStore: mutationStore
            )
        }
    }

    /// Clears a terminal operation (Done button, pill dismiss, auto-clear).
    func acknowledge() {
        guard operation?.status.isTerminal == true else { return }
        autoClearTask?.cancel()
        autoClearTask = nil
        resolverTask?.cancel()
        resolverTask = nil
        followerTask?.cancel()
        followerTask = nil
        cancellationTask?.cancel()
        cancellationTask = nil
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
                // Finished while suspended. Mark the handoff before cancelling
                // the stale stream so its cancellation path cannot start a
                // second follower.
                operation.isServerSynced = true
                self.streamTask?.cancel()
                guard let manager = self.activeManager,
                      let mutationStore = self.activeMutationStore else { return }
                self.startFollowingServerActivity(
                    operation,
                    activityID: activityID,
                    client: client,
                    manager: manager,
                    mutationStore: mutationStore,
                    fallbackFailureMessage: nil,
                    announceReconnect: true
                )
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
        var handedOffToFollower = false
        defer {
            streamTask = nil
            if !handedOffToFollower, followerTask == nil, cancellationTask == nil {
                endBackgroundTask()
            }
        }

        do {
            if operation.kind == .containerRedeploy {
                try await runContainerRedeploy(operation, client: client)
            } else if operation.kind == .containerUpdate {
                // Per-target POSTs with partial-failure reporting; each
                // response is authoritative, so this path terminates the
                // operation itself instead of falling through.
                await runContainerUpdate(operation, client: client,
                                         manager: manager, mutationStore: mutationStore)
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
            guard !userCancelRequested else { return }

            if operation.kind.isRequestBacked
                || operation.receivedTerminalSuccess
                || !serverSyncSupported {
                withAnimation(Motion.state) {
                    operation.status = .success
                    operation.currentPhase = "Complete"
                }
                await completeSuccessfully(
                    operation,
                    manager: manager,
                    mutationStore: mutationStore
                )
            } else if let activityID = await resolveServerActivity(
                for: operation,
                client: client
            ) {
                // v2 EOF without `done` is not a verdict. Follow the captured
                // Activity (or the fallback resolver's match on older v2) to
                // its persisted terminal state.
                guard self.operation?.id == operation.id,
                      !operation.status.isTerminal,
                      !userCancelRequested else { return }
                handedOffToFollower = true
                startFollowingServerActivity(
                    operation,
                    activityID: activityID,
                    client: client,
                    manager: manager,
                    mutationStore: mutationStore,
                    fallbackFailureMessage: nil,
                    announceReconnect: true
                )
            } else {
                markFailed("Operation stream ended before completion", operation: operation)
            }
        } catch {
            guard self.operation?.id == operation.id, !operation.status.isTerminal else { return }
            if userCancelRequested || operation.isServerSynced {
                return
            } else if let message = explicitOperationFailureMessage(error) {
                // The SDK turns a non-empty operation error frame into this
                // typed failure. It is authoritative and should surface now.
                markFailed(message, operation: operation)
            } else if serverSyncSupported,
                      let activityID = await resolveServerActivity(for: operation, client: client) {
                // The stream died but the server-side operation continues (the
                // backend detaches jobs from the request lifecycle) — follow
                // the activity record until it lands.
                guard self.operation?.id == operation.id,
                      !operation.status.isTerminal,
                      !userCancelRequested else { return }
                handedOffToFollower = true
                startFollowingServerActivity(
                    operation,
                    activityID: activityID,
                    client: client,
                    manager: manager,
                    mutationStore: mutationStore,
                    fallbackFailureMessage: friendlyErrorMessage(error),
                    announceReconnect: true
                )
            } else {
                markFailed(friendlyErrorMessage(error), operation: operation)
            }
        }
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
                            client: ArcaneClient) throws -> NDJSONStream<OperationStreamEvent> {
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
        let details = try await client.containers.redeploy(
            envID: operation.envID,
            id: operation.targetID
        )
        captureResponseActivityID(details.activityID, for: operation)
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
            operation.activityLookupTargetID = target.id
            operation.serverActivityID = nil
            if serverSyncSupported {
                startActivityResolver(for: operation, client: client)
            }
            updatePhase(targets.count == 1 ? "Updating" : "Updating \(target.name)", on: operation)
            append(text: "Updating \(target.name)…", isError: false, to: operation)
            liveActivity.update(for: operation, immediate: false)
            do {
                let result = try await client.updater.updateContainer(target.id, envID: operation.envID)
                captureResponseActivityID(result.activityID, for: operation)
                ingest(result, into: operation)
                failures.append(contentsOf: failureMessages(in: result))
            } catch is CancellationError {
                return
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
            return
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

    private func ingest(_ event: OperationStreamEvent, into operation: DeploymentOperation) {
        // Keep a small overlap so persisted Activity messages created around
        // the last live frame are never lost when a suspended stream resumes.
        operation.serverSyncCursor = Date().addingTimeInterval(-2)
        captureStreamActivityID(event.activityID, for: operation)
        if event.done == true {
            operation.receivedTerminalSuccess = true
        }

        let isError = event.error?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        if let display = displayText(for: event) {
            append(text: display, isError: isError, to: operation)
        }
        if !isError {
            if let phase = (event.phase ?? event.status)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
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

    // MARK: Docker output

    /// Current servers send Docker's rendered CLI lines in `log`, exactly as
    /// the web operation watcher displays them. Preserve those bytes as text:
    /// leading spaces, trailing spaces, and empty lines are all meaningful
    /// terminal output. The structured fields remain only as a v1 fallback.
    private func displayText(for event: OperationStreamEvent) -> String? {
        if let log = event.log {
            return log
        }
        if let error = event.error?.trimmingCharacters(in: .whitespacesAndNewlines),
           !error.isEmpty {
            return error
        }
        if let stream = event.stream {
            return stream
        }

        var output = ""
        if let id = event.id, !id.isEmpty {
            output = "\(id):"
        }
        if let status = event.status, !status.isEmpty {
            if !output.isEmpty { output += " " }
            output += status
        }
        if let progress = event.progress, !progress.isEmpty {
            if !output.isEmpty { output += " " }
            output += progress
        }
        return output.isEmpty ? nil : output
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

    private func updateProgress(from event: OperationStreamEvent,
                                on operation: DeploymentOperation) {
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

    private func captureStreamActivityID(_ rawID: String?,
                                         for operation: DeploymentOperation) {
        guard operation.serverActivityID == nil,
              let id = rawID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty else { return }
        operation.serverActivityID = id
        resolverTask?.cancel()
        resolverTask = nil
    }

    private func captureResponseActivityID(_ rawID: String?,
                                           for operation: DeploymentOperation) {
        resolverTask?.cancel()
        resolverTask = nil
        guard let id = rawID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty else { return }
        operation.serverActivityID = id
    }

    private func explicitOperationFailureMessage(_ error: Error) -> String? {
        guard let arcaneError = error as? ArcaneError,
              case .server(let code, let message) = arcaneError,
              code == "OPERATION_FAILED" else { return nil }
        return message
    }

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

    private func startActivityResolver(for operation: DeploymentOperation,
                                       client: ArcaneClient) {
        resolverTask?.cancel()
        resolverTask = Task { [weak self] in
            _ = await self?.resolveServerActivity(for: operation, client: client)
        }
    }

    /// Fallback for older v2 streams that omit `activityId`, plus
    /// request-backed operations before their response returns. Current
    /// project/image streams capture the direct ID and never need this path.
    private func resolveServerActivity(for operation: DeploymentOperation,
                                       client: ArcaneClient) async -> String? {
        if let id = operation.serverActivityID { return id }
        let type = Self.activityType(for: operation.kind)
        let target = operation.activityLookupTargetID
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
                guard operation.activityLookupTargetID == target else { return nil }
                if let id = operation.serverActivityID { return id }
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
            } catch is CancellationError {
                return nil
            } catch {
                // Transient — retry below.
            }
            do {
                try await Task.sleep(for: .milliseconds(400 * attempt))
            } catch {
                return nil
            }
        }
        return nil
    }

    private func startFollowingServerActivity(
        _ operation: DeploymentOperation,
        activityID: String,
        client: ArcaneClient,
        manager: ArcaneClientManager,
        mutationStore: ResourceMutationStore,
        fallbackFailureMessage: String?,
        announceReconnect: Bool
    ) {
        operation.isServerSynced = true
        followerTask?.cancel()
        followerTask = Task { [weak self] in
            guard let self else { return }
            let reachedTerminal = await self.followServerActivity(
                operation,
                activityID: activityID,
                client: client,
                manager: manager,
                mutationStore: mutationStore,
                fallbackFailureMessage: fallbackFailureMessage,
                announceReconnect: announceReconnect
            )
            if reachedTerminal {
                self.endBackgroundTask()
            }
        }
    }

    private func cancelServerOperation(
        _ operation: DeploymentOperation,
        client: ArcaneClient,
        manager: ArcaneClientManager,
        mutationStore: ResourceMutationStore
    ) async {
        defer {
            cancellationTask = nil
            if streamTask == nil, followerTask == nil {
                endBackgroundTask()
            }
        }

        guard self.operation?.id == operation.id, !operation.status.isTerminal else { return }
        let activityID: String?
        if let capturedID = operation.serverActivityID {
            activityID = capturedID
        } else {
            activityID = await resolveServerActivity(for: operation, client: client)
        }
        guard !Task.isCancelled else { return }
        guard let activityID else {
            markFailed("Couldn't find the server activity to cancel", operation: operation)
            return
        }

        do {
            let activity = try await client.activities.cancel(
                envID: operation.envID,
                activityID: activityID
            )
            operation.serverActivityID = activity.id
        } catch is CancellationError {
            return
        } catch {
            markFailed(friendlyErrorMessage(error), operation: operation)
            return
        }

        _ = await followServerActivity(
            operation,
            activityID: activityID,
            client: client,
            manager: manager,
            mutationStore: mutationStore,
            fallbackFailureMessage: nil,
            announceReconnect: false
        )
    }

    /// Polls a captured Activity through its persisted terminal state and
    /// backfills output. This is used after stream loss and after a server
    /// cancellation request.
    private func followServerActivity(_ operation: DeploymentOperation,
                                      activityID: String,
                                      client: ArcaneClient,
                                      manager: ArcaneClientManager,
                                      mutationStore: ResourceMutationStore,
                                      fallbackFailureMessage: String?,
        announceReconnect: Bool) async -> Bool {
        operation.isServerSynced = true
        if operation.serverSyncCursor == nil {
            operation.serverSyncCursor = operation.startedAt.addingTimeInterval(-2)
        }
        if announceReconnect {
            append(
                text: "Stream interrupted — following the server activity…",
                isError: false,
                to: operation
            )
            updatePhase("Reconnecting", on: operation)
        } else {
            updatePhase("Cancelling", on: operation)
        }
        liveActivity.update(for: operation, immediate: true)

        var consecutiveFailures = 0
        while !Task.isCancelled {
            guard self.operation?.id == operation.id else { return false }
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
                    return true
                case .failed:
                    markFailed(detail.activity.error ?? "Failed on server", operation: operation)
                    return true
                case .cancelled:
                    markFailed("Cancelled", operation: operation)
                    return true
                case .queued, .running, .unknown(_):
                    if !announceReconnect {
                        updatePhase("Cancelling", on: operation)
                        liveActivity.update(for: operation, immediate: false)
                    }
                }
            } catch is CancellationError {
                return false
            } catch {
                consecutiveFailures += 1
                if consecutiveFailures >= 8 {
                    markFailed(
                        fallbackFailureMessage ?? friendlyErrorMessage(error),
                        operation: operation
                    )
                    return true
                }
            }
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return false
            }
        }
        return false
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
            do {
                try await Task.sleep(for: Self.terminalPillLinger)
            } catch {
                return
            }
            guard let self else { return }
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
        followerTask?.cancel()
        followerTask = nil
        cancellationTask?.cancel()
        cancellationTask = nil
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
