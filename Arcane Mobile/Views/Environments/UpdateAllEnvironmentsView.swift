import Foundation
import SwiftUI
import Arcane

/// Fleet-wide Arcane self-upgrade, mirroring the web app's "Update All" button
/// on the environments page: online remote agents are upgraded first, then the
/// manager itself restarts. Presented as a sheet from the dashboard's
/// Environments section; the ready screen doubles as the confirmation step
/// (like the web dialog).
struct UpdateAllEnvironmentsView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutationStore
    @SwiftUI.Environment(\.dismiss) private var dismiss

    let environmentCount: Int
    /// Skip the in-sheet confirmation and trigger the run as soon as preflight
    /// finds no job in progress. The dashboard confirms on its own button.
    var startsImmediately = false

    private enum Phase: Equatable {
        case loading
        case ready(lastJob: EnvironmentUpdateJob?)
        case triggering
        case polling(EnvironmentUpdateJob)
        case reconnecting(EnvironmentUpdateJob)
        case finished(EnvironmentUpdateJob, note: String?)
        case unsupported(String)
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var pollTask: Task<Void, Never>?

    /// The manager environment. The server ignores the path segment for these
    /// endpoints — the manager always orchestrates the whole fleet.
    private let managerEnvID = EnvironmentID(rawValue: "0")

    private var isAdmin: Bool { manager.currentUser?.isAdmin == true }

    /// Collapses polling payloads into meaningful presentation changes so the
    /// supporting content does not reanimate on every three-second refresh.
    private var phaseKey: Int {
        switch phase {
        case .loading: 0
        case .ready: 1
        case .triggering: 2
        case .polling(let job): job.status == .pendingRestart ? 4 : 3
        case .reconnecting: 5
        case .finished: 6
        case .unsupported: 7
        case .failed: 8
        }
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 32) {
                    if !isAdmin {
                        ContentUnavailableView(
                            "Admins Only",
                            systemImage: "lock.shield",
                            description: Text("Updating all environments requires an administrator account.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 240)
                    } else {
                        phaseContent
                    }
                }
                .frame(maxWidth: 680)
                .padding(.horizontal, 20)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
                .frame(minHeight: proxy.size.height, alignment: .center)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .navigationTitle("Update All")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(doneTitle) { dismiss() }
            }
        }
        .interactiveDismissDisabled(phase == .triggering)
        .task {
            guard isAdmin else { return }
            await preflight()
        }
        .onDisappear { pollTask?.cancel() }
    }

    @ViewBuilder
    private var phaseContent: some View {
        if let sceneModel {
            VStack(spacing: 24) {
                FleetUpdateScene(model: sceneModel)

                Group {
                    phaseDetails
                }
                .transition(.opacity)
                .motionAwareAnimation(Motion.state, value: phaseKey)
            }
        } else if case .unsupported(let message) = phase {
            ContentUnavailableView(
                "Not Available",
                systemImage: "lock.shield",
                description: Text(message)
            )
            .frame(maxWidth: .infinity, minHeight: 240)
        } else if case .failed(let message) = phase {
            VStack(spacing: 20) {
                ContentUnavailableView(
                    "Update All Failed",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
                .frame(maxWidth: .infinity, minHeight: 240)
                retryButton
            }
        }
    }

    @ViewBuilder
    private var phaseDetails: some View {
        switch phase {
        case .ready(let lastJob):
            readyDetails(lastJob: lastJob)
        case .polling, .reconnecting:
            EmptyView()
        case .finished(let job, _):
            finishedDetails(job: job)
        case .loading, .triggering, .unsupported, .failed:
            EmptyView()
        }
    }

    private var sceneModel: FleetUpdateSceneModel? {
        switch phase {
        case .loading:
            return FleetUpdateSceneModel(
                kind: .loading,
                title: "Checking readiness",
                subtitle: "Reading the manager's update status"
            )
        case .ready:
            return FleetUpdateSceneModel(
                kind: .ready,
                title: "Update every environment",
                subtitle: environmentCount == 1
                    ? "1 environment · latest release"
                    : "\(environmentCount) environments · latest release"
            )
        case .triggering:
            return FleetUpdateSceneModel(
                kind: .starting,
                title: "Starting the update",
                subtitle: "Contacting the manager"
            )
        case .polling(let job):
            let results = resultsInProcessingOrder(job.results ?? [])
            let done = completedResultCount(results)
            let progress: Double? = results.isEmpty
                ? nil
                : Double(done) / Double(results.count)
            let activeEnvironment = results.first { $0.status == .updating }

            if job.status == .pendingRestart {
                return FleetUpdateSceneModel(
                    kind: .restarting,
                    title: "Restarting the manager",
                    subtitle: "The environment updates are complete",
                    progress: progress,
                    completedCount: done,
                    totalCount: results.count,
                    activeEnvironment: activeEnvironment,
                    ringEnvironments: ringModels(for: results)
                )
            }

            let subtitle = results.isEmpty
                ? "Preparing environments"
                : "\(done) of \(results.count) complete"
            return FleetUpdateSceneModel(
                kind: .updating,
                title: "Updating environments",
                subtitle: subtitle,
                progress: progress,
                completedCount: done,
                totalCount: results.count,
                activeEnvironment: activeEnvironment,
                ringEnvironments: ringModels(for: results)
            )
        case .reconnecting(let job):
            let results = resultsInProcessingOrder(job.results ?? [])
            let done = completedResultCount(results)
            return FleetUpdateSceneModel(
                kind: .reconnecting,
                title: "Reconnecting",
                subtitle: "Waiting for the manager to return",
                progress: results.isEmpty ? nil : Double(done) / Double(results.count),
                completedCount: done,
                totalCount: results.count,
                activeEnvironment: results.first { $0.status == .updating },
                ringEnvironments: ringModels(for: results)
            )
        case .finished(let job, let note):
            let results = resultsInProcessingOrder(job.results ?? [])
            let counts = resultCounts(results)
            let done = completedResultCount(results)
            let kind: FleetUpdateSceneKind
            let title: String
            if job.status == .failed {
                kind = .failed
                title = "Update failed"
            } else if note != nil || counts.failed > 0 || counts.skipped > 0 {
                kind = .warning
                title = note == nil ? "Finished with issues" : "Manager restarting"
            } else {
                kind = .completed
                title = "All updated"
            }
            return FleetUpdateSceneModel(
                kind: kind,
                title: title,
                subtitle: note ?? (job.status == .failed
                    ? (job.error ?? "The environment update failed.")
                    : lastRunSummary(job: job)),
                progress: results.isEmpty ? nil : Double(done) / Double(results.count),
                completedCount: done,
                totalCount: results.count,
                activeEnvironment: job.isTerminal
                    ? nil
                    : results.first { $0.status == .updating },
                ringEnvironments: ringModels(for: results)
            )
        case .unsupported, .failed:
            return nil
        }
    }

    private var doneTitle: String {
        if case .finished = phase { return "Done" }
        return "Close"
    }

    // MARK: - Ready (confirmation step)

    private func readyDetails(lastJob: EnvironmentUpdateJob?) -> some View {
        VStack(spacing: 18) {
            if let lastJob {
                lastRunRow(job: lastJob)
            }

            Text("Remote agents update first. The manager restarts last and can briefly interrupt the connection.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)

            Button(role: .destructive) {
                Task { await trigger() }
            } label: {
                Label("Update All", systemImage: "arrow.up.circle.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.red)
        }
    }

    private func lastRunRow(job: EnvironmentUpdateJob) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Image(systemName: job.status == .completed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(job.status == .completed ? Color.green : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Last run")
                        .font(.subheadline.weight(.semibold))
                    Text(lastRunSummary(job: job))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let completedAt = job.completedAt {
                    Text(completedAt.formatted(.relative(presentation: .named)))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 16)
            Divider()
        }
    }

    private func lastRunSummary(job: EnvironmentUpdateJob) -> String {
        if job.status == .failed {
            return job.error ?? "Failed"
        }
        let counts = resultCounts(job.results ?? [])
        var parts = ["\(counts.updated) updated"]
        if counts.failed > 0 { parts.append("\(counts.failed) failed") }
        if counts.skipped > 0 { parts.append("\(counts.skipped) skipped") }
        if let version = displayVersion(job.managerTargetVersion) {
            parts.append(version)
        }
        return parts.joined(separator: " · ")
    }

    /// Hides digest-style targets (`sha256:…`) that read as noise in the UI.
    private func displayVersion(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, !raw.contains(":"), raw.count <= 20 else { return nil }
        return raw
    }

    // MARK: - Finished

    private func finishedDetails(job: EnvironmentUpdateJob) -> some View {
        let results = resultsInProcessingOrder(job.results ?? [])
        let counts = resultCounts(results)

        return metricsStrip(updated: counts.updated, failed: counts.failed, skipped: counts.skipped)
    }

    private func metricsStrip(updated: Int, failed: Int, skipped: Int) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                counterMetric(label: "Updated", value: updated, tint: .green)
                Divider().frame(height: 56)
                counterMetric(label: "Failed", value: failed, tint: .red)
                Divider().frame(height: 56)
                counterMetric(label: "Skipped", value: skipped, tint: .gray)
            }
            .padding(.vertical, 16)
            Divider()
        }
    }

    private func counterMetric(label: String, value: Int, tint: Color) -> some View {
        VStack(spacing: 4) {
            Text(verbatim: String(value))
                .font(.system(.title, design: .rounded).weight(.semibold))
                .foregroundStyle(tint)
                .contentTransition(.numericText())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private func completedResultCount(_ results: [EnvironmentUpdateResult]) -> Int {
        results.filter { isCompletedResult($0) }.count
    }

    private func resultsInProcessingOrder(
        _ results: [EnvironmentUpdateResult]
    ) -> [EnvironmentUpdateResult] {
        let remoteResults = results.filter { $0.environmentId != managerEnvID.rawValue }
        let managerResults = results.filter { $0.environmentId == managerEnvID.rawValue }
        return remoteResults + managerResults
    }

    private func isCompletedResult(_ result: EnvironmentUpdateResult) -> Bool {
        return switch result.status {
        case .pending, .updating:
            false
        case .updated, .upToDate, .triggered, .skippedOffline, .failed, .unknown:
            true
        }
    }

    private func ringModels(
        for results: [EnvironmentUpdateResult]
    ) -> [FleetUpdateRingEnvironment] {
        results.enumerated().map { index, result in
            FleetUpdateRingEnvironment(
                result: result,
                slotIndex: index,
                totalCount: results.count
            )
        }
    }

    private func resultCounts(
        _ results: [EnvironmentUpdateResult]
    ) -> (updated: Int, failed: Int, skipped: Int) {
        (
            results.filter {
                $0.status == .updated || $0.status == .upToDate || $0.status == .triggered
            }.count,
            results.filter { $0.status == .failed }.count,
            results.filter { $0.status == .skippedOffline }.count
        )
    }

    private var retryButton: some View {
        Button {
            Task { await preflight() }
        } label: {
            Label("Try Again", systemImage: "arrow.clockwise")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    // MARK: - Networking

    private func preflight() async {
        guard let client = manager.client else {
            phase = .failed("Not connected")
            return
        }
        phase = .loading
        do {
            let job = try await client.system.updateAllStatus(envID: managerEnvID)
            if job.isTerminal {
                if startsImmediately {
                    await trigger()
                } else {
                    phase = .ready(lastJob: job)
                }
            } else {
                // A job is already running (started here earlier, or from the
                // web UI) — resume watching it instead of offering a new run.
                phase = .polling(job)
                startPolling(client: client, lastKnown: job)
            }
        } catch ArcaneError.notFound {
            // No job has ever run. (Also what an old server without the
            // endpoint returns — the POST disambiguates.)
            await readyOrStart()
        } catch ArcaneError.decoding {
            await readyOrStart()
        } catch {
            phase = .failed(friendlyErrorMessage(error))
        }
    }

    private func readyOrStart() async {
        if startsImmediately {
            await trigger()
        } else {
            phase = .ready(lastJob: nil)
        }
    }

    private func trigger() async {
        guard let client = manager.client else {
            phase = .failed("Not connected")
            return
        }
        phase = .triggering
        do {
            let requestClient = try ActivityBatchID.scopedClient(client)
            let job = try await requestClient.system.triggerUpdateAll(envID: managerEnvID)
            phase = .polling(job)
            startPolling(client: client, lastKnown: job)
        } catch ArcaneError.conflict {
            // Someone beat us to it — attach to the job that's already running.
            await preflight()
        } catch ArcaneError.notFound {
            phase = .unsupported("This Arcane server doesn't support fleet updates. Update the server first.")
        } catch let error as ArcaneError {
            if case .server(_, let message) = error, !message.isEmpty {
                // Agent-mode servers reject update-all with a 400 explaining
                // it's managed on the manager.
                phase = .unsupported(message)
            } else {
                phase = .failed(friendlyErrorMessage(error))
            }
        } catch {
            phase = .failed(friendlyErrorMessage(error))
        }
    }

    private func startPolling(client: ArcaneClient, lastKnown initialJob: EnvironmentUpdateJob) {
        pollTask?.cancel()
        pollTask = Task {
            var lastKnown = initialJob
            var consecutiveFailures = 0
            // ~3 minutes of failed ticks before giving an optimistic verdict —
            // the manager container replacement can take a while.
            let maxFailures = 60

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                if Task.isCancelled { return }
                do {
                    let job = try await client.system.updateAllStatus(envID: managerEnvID)
                    if Task.isCancelled { return }
                    consecutiveFailures = 0
                    lastKnown = job
                    if job.isTerminal {
                        finish(job, note: nil)
                        return
                    }
                    phase = .polling(job)
                } catch {
                    // Expected while the manager replaces itself: connection
                    // refused, 502s from a proxy, or 401s before auth is back.
                    consecutiveFailures += 1
                    if consecutiveFailures == 2 {
                        phase = .reconnecting(lastKnown)
                    }
                    if consecutiveFailures >= maxFailures {
                        let managerDone = lastKnown.status == .pendingRestart
                            && (lastKnown.managerResult?.status == .updated
                                || lastKnown.managerResult?.status == .triggered
                                || lastKnown.managerResult?.status == .updating)
                        let note = managerDone
                            ? "The Arcane manager is restarting — check back in a minute."
                            : "Lost connection before the update finished. Check the server once it's reachable again."
                        finish(lastKnown, note: note)
                        return
                    }
                }
            }
        }
    }

    private func finish(_ job: EnvironmentUpdateJob, note: String?) {
        phase = .finished(job, note: note)
        if note == nil {
            let failedCount = (job.results ?? []).filter { $0.status == .failed }.count
            if job.status == .completed && failedCount == 0 {
                showToast(.success("All environments updated"))
            } else if job.status == .failed {
                showToast(.error(job.error ?? "Fleet update failed"))
            }
        }
        Task {
            await manager.cached?.invalidateGlobal(paths: ["environments"])
            mutationStore.markChanged(kind: .environments)
        }
    }
}

// MARK: - Update scene

enum FleetUpdateSceneKind: Equatable {
    case loading
    case ready
    case starting
    case updating
    case restarting
    case reconnecting
    case completed
    case warning
    case failed

    var tint: Color {
        switch self {
        case .reconnecting, .warning: .orange
        case .completed: .green
        case .failed: .red
        case .loading, .ready, .starting, .updating, .restarting: .accentColor
        }
    }

    var symbol: String {
        switch self {
        case .loading: "ellipsis"
        case .ready: "arrow.up.circle.fill"
        case .starting, .updating: "arrow.triangle.2.circlepath"
        case .restarting: "antenna.radiowaves.left.and.right"
        case .reconnecting: "wifi"
        case .completed: "checkmark"
        case .warning: "exclamationmark"
        case .failed: "xmark"
        }
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .warning, .failed: true
        case .loading, .ready, .starting, .updating, .restarting, .reconnecting: false
        }
    }
}

struct FleetUpdateRingEnvironment: Identifiable, Equatable {
    let result: EnvironmentUpdateResult
    let slotIndex: Int
    let totalCount: Int

    var id: String { result.id }
}

struct FleetUpdateSceneModel: Equatable {
    let kind: FleetUpdateSceneKind
    let title: String
    let subtitle: String
    let progress: Double?
    let completedCount: Int
    let totalCount: Int
    let activeEnvironment: EnvironmentUpdateResult?
    let ringEnvironments: [FleetUpdateRingEnvironment]

    init(
        kind: FleetUpdateSceneKind,
        title: String,
        subtitle: String,
        progress: Double? = nil,
        completedCount: Int = 0,
        totalCount: Int = 0,
        activeEnvironment: EnvironmentUpdateResult? = nil,
        ringEnvironments: [FleetUpdateRingEnvironment] = []
    ) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.progress = progress
        self.completedCount = completedCount
        self.totalCount = totalCount
        self.activeEnvironment = activeEnvironment
        self.ringEnvironments = ringEnvironments
    }

    var showsPercentage: Bool {
        kind == .updating && activeEnvironment == nil && progress != nil && totalCount > 0
    }

    var showsActiveEnvironment: Bool {
        activeEnvironment != nil
    }

    var ringFraction: Double {
        if !kind.isTerminal, totalCount > 0, let progress {
            return min(max(progress, 0), 1)
        }

        return switch kind {
        case .ready: 0
        case .loading, .starting, .updating: 0.14
        case .restarting, .reconnecting, .completed, .warning, .failed: 1
        }
    }

    var percentage: Int {
        Int((ringFraction * 100).rounded())
    }

    var accessibilityValue: String {
        let progressDescription = totalCount > 0
            ? "\(completedCount) of \(totalCount) environments complete"
            : subtitle
        guard let activeEnvironment else { return progressDescription }

        if kind == .reconnecting {
            return "\(activeEnvironment.environmentName) updating. \(progressDescription). \(subtitle)"
        }

        return "\(activeEnvironment.environmentName) updating. \(progressDescription)"
    }
}

struct FleetUpdateScene: View {
    let model: FleetUpdateSceneModel

    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var focusSize: CGFloat = 96
    @State private var hasAppeared = false
    @State private var completionPulse = 0

    var body: some View {
        VStack(spacing: 24) {
            focus

            if !model.ringEnvironments.isEmpty {
                FleetUpdatePipeline(
                    environments: model.ringEnvironments,
                    activeEnvironmentID: model.activeEnvironment?.id,
                    tint: model.kind.tint
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }

            VStack(spacing: 6) {
                Text(model.title)
                    .font(.title.weight(.bold))
                    .multilineTextAlignment(.center)
                    .contentTransition(.interpolate)

                Text(model.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.interpolate)
                    .motionAwareAnimation(Motion.state, value: model.subtitle)

                if let active = model.activeEnvironment, model.showsActiveEnvironment {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .symbolEffect(.rotate, options: .repeating, isActive: !reduceMotion)
                        Text(active.environmentName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(model.kind.tint)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(model.kind.tint.opacity(0.12), in: Capsule())
                    .padding(.top, 6)
                    .id(active.id)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 248)
        .padding(.vertical, 4)
        .background {
            // Square so the glow is a true circle, never an oval behind the disc.
            RadialGradient(
                colors: [model.kind.tint.opacity(0.12), model.kind.tint.opacity(0.03), .clear],
                center: .center,
                startRadius: 0,
                endRadius: 120
            )
            .frame(width: 260, height: 260)
            .blur(radius: 10)
            .offset(y: -40)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .opacity(hasAppeared ? 1 : 0)
        .scaleEffect(reduceMotion || hasAppeared ? 1 : 0.94)
        .motionAwareAnimation(Motion.updateStage, value: model.kind)
        .motionAwareAnimation(Motion.updateStage, value: model.title)
        .motionAwareAnimation(Motion.updateStage, value: model.activeEnvironment?.id)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.title)
        .accessibilityValue(model.accessibilityValue)
        .onAppear {
            withAnimation(reduceMotion ? Motion.reducedFallback : Motion.updateStage) {
                hasAppeared = true
            }
            if model.kind.isTerminal {
                completionPulse += 1
            }
        }
        .onChange(of: model.kind) { _, kind in
            if kind.isTerminal {
                completionPulse += 1
            }
        }
    }

    /// Tinted disc carrying the phase symbol, or the percentage while the
    /// fleet updates with no single environment in flight. Progress itself
    /// lives in the pipeline connectors, so there is no ring here.
    private var focus: some View {
        ZStack {
            Circle()
                .fill(model.kind.tint.opacity(model.kind.isTerminal ? 0.16 : 0.10))
            Circle()
                .stroke(model.kind.tint.opacity(0.2), lineWidth: 1)

            animatedSymbol
                .opacity(model.showsPercentage ? 0 : 1)
                .scaleEffect(model.showsPercentage ? 0.82 : 1)

            Text(verbatim: "\(model.percentage)%")
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .foregroundStyle(model.kind.tint)
                .contentTransition(.numericText())
                .opacity(model.showsPercentage ? 1 : 0)
                .scaleEffect(model.showsPercentage ? 1 : 0.82)
                .motionAwareAnimation(Motion.updateStage, value: model.percentage)
        }
        .frame(width: min(focusSize, 96), height: min(focusSize, 96))
        .scaleEffect(model.kind.isTerminal ? 1.06 : 1)
        .motionAwareAnimation(Motion.updateStage, value: model.showsPercentage)
        .motionAwareAnimation(Motion.updateStage, value: model.kind.isTerminal)
    }

    private var baseSymbol: some View {
        Image(systemName: model.kind.symbol)
            .font(.system(.largeTitle, design: .rounded).weight(.semibold))
            .foregroundStyle(model.kind.tint)
            .contentTransition(.symbolEffect(.replace))
    }

    @ViewBuilder
    private var animatedSymbol: some View {
        switch model.kind {
        case .loading:
            baseSymbol
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !reduceMotion)
        case .starting:
            baseSymbol
                .symbolEffect(.rotate, options: .repeating, isActive: !reduceMotion)
        case .updating:
            if model.showsPercentage {
                baseSymbol
            } else {
                baseSymbol
                    .symbolEffect(.rotate, options: .repeating, isActive: !reduceMotion)
            }
        case .restarting:
            baseSymbol
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !reduceMotion)
        case .reconnecting:
            baseSymbol
                .symbolEffect(
                    .variableColor.iterative.reversing,
                    options: .repeating,
                    isActive: !reduceMotion
                )
        case .completed, .warning, .failed:
            if reduceMotion {
                baseSymbol
            } else {
                baseSymbol
                    .symbolEffect(.bounce, options: .nonRepeating, value: completionPulse)
            }
        case .ready:
            baseSymbol
        }
    }
}

private enum FleetUpdateBubblePhase: CaseIterable {
    case resting
    case upperTrailing
    case lowerTrailing
    case lowerLeading
    case upperLeading

    var horizontalOffset: CGFloat {
        switch self {
        case .resting: 0
        case .upperTrailing: 2.8
        case .lowerTrailing: 2.1
        case .lowerLeading: -2.7
        case .upperLeading: -2.2
        }
    }

    var verticalOffset: CGFloat {
        switch self {
        case .resting: 0
        case .upperTrailing: -2.2
        case .lowerTrailing: 2.5
        case .lowerLeading: 1.8
        case .upperLeading: -2.6
        }
    }

    var scale: CGFloat {
        switch self {
        case .resting: 1
        case .upperTrailing: 1.006
        case .lowerTrailing: 1.003
        case .lowerLeading: 0.996
        case .upperLeading: 0.999
        }
    }
}

nonisolated enum FleetUpdateBubblePresentation: Equatable, Sendable {
    case pending
    case updating
    case succeeded
    case skipped
    case failed
    case unknown

    init(status: EnvironmentUpdateResultStatus) {
        self = switch status {
        case .pending: .pending
        case .updating: .updating
        case .updated, .upToDate, .triggered: .succeeded
        case .skippedOffline: .skipped
        case .failed: .failed
        case .unknown: .unknown
        }
    }

    var terminalSymbol: String? {
        switch self {
        case .pending, .updating: nil
        case .succeeded: "checkmark"
        case .skipped: "wifi.slash"
        case .failed: "xmark"
        case .unknown: "questionmark"
        }
    }

    var isTerminal: Bool {
        terminalSymbol != nil
    }
}

/// Left-to-right pipeline in processing order: each environment is a bubble,
/// joined by connector bars that fill as the run advances. The active bubble
/// wears a spinner and floats; pending bubbles drift gently; finished ones
/// settle with their result glyph.
private struct FleetUpdatePipeline: View {
    let environments: [FleetUpdateRingEnvironment]
    let activeEnvironmentID: String?
    let tint: Color

    private var bubbleSize: CGFloat {
        switch environments.count {
        case ...5: 40
        case 6...8: 32
        case 9...12: 26
        default: 20
        }
    }

    private func isSettled(_ environment: FleetUpdateRingEnvironment) -> Bool {
        FleetUpdateBubblePresentation(status: environment.result.status).isTerminal
    }

    /// Connector after `index`: full once that environment is settled, half
    /// while it is the one updating, empty otherwise.
    private func connectorFill(after index: Int) -> CGFloat {
        let environment = environments[index]
        if isSettled(environment) { return 1 }
        if environment.id == activeEnvironmentID { return 0.5 }
        return 0
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(environments.enumerated()), id: \.element.id) { index, environment in
                FleetUpdateBubble(
                    environment: environment,
                    index: index,
                    isActive: environment.id == activeEnvironmentID,
                    tint: tint,
                    size: bubbleSize
                )
                if index < environments.count - 1 {
                    FleetUpdateConnector(fill: connectorFill(after: index), tint: tint)
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: 420)
        .accessibilityHidden(true)
    }
}

private struct FleetUpdateConnector: View {
    let fill: CGFloat
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.16))
                Capsule()
                    .fill(tint)
                    .frame(width: max(0, proxy.size.width * fill))
            }
        }
        .frame(height: 3)
        .frame(minWidth: 8, maxWidth: .infinity)
        .padding(.horizontal, 6)
        .animation(Motion.updateConnector, value: fill)
    }
}

private struct FleetUpdateBubble: View {
    let environment: FleetUpdateRingEnvironment
    let index: Int
    let isActive: Bool
    let tint: Color
    let size: CGFloat

    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isManager: Bool { environment.result.environmentId == "0" }

    private var presentation: FleetUpdateBubblePresentation {
        FleetUpdateBubblePresentation(status: environment.result.status)
    }

    private var bubbleTint: Color {
        switch presentation {
        case .pending, .updating: tint
        case .succeeded: .green
        case .skipped: .gray
        case .failed: .red
        case .unknown: .orange
        }
    }

    private var symbol: String {
        presentation.terminalSymbol ?? (isManager ? "crown.fill" : "server.rack")
    }

    private var showsSpinner: Bool {
        isActive && presentation == .updating
    }

    /// Active bubble bobs visibly; pending ones drift half as far, each
    /// starting from a different phase so the row doesn't move in lockstep.
    private var floatPhases: [FleetUpdateBubblePhase] {
        guard !reduceMotion, !presentation.isTerminal else { return [.resting] }
        let all = FleetUpdateBubblePhase.allCases
        let shift = index % all.count
        return Array(all[shift...] + all[..<shift])
    }

    private var floatScale: CGFloat { isActive ? 1.6 : 0.8 }

    private var spinnerPhases: [Double] {
        reduceMotion || !showsSpinner ? [0] : [0, 360]
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(bubbleTint.opacity(0.18), lineWidth: 2.5)
                .frame(width: size + 10, height: size + 10)
                .opacity(showsSpinner ? 1 : 0)
                .scaleEffect(showsSpinner ? 1 : 0.85)

            Circle()
                .trim(from: 0.08, to: 0.72)
                .stroke(bubbleTint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .frame(width: size + 10, height: size + 10)
                .opacity(showsSpinner ? 1 : 0)
                .scaleEffect(showsSpinner ? 1 : 0.85)
                .phaseAnimator(spinnerPhases) { content, rotation in
                    content.rotationEffect(.degrees(rotation))
                } animation: { _ in
                    Motion.updateBubbleSpinner
                }

            ZStack {
                Circle()
                    .fill(bubbleTint.opacity(isActive || presentation.isTerminal ? 0.2 : 0.1))
                Circle()
                    .stroke(bubbleTint.opacity(isActive || presentation.isTerminal ? 0.5 : 0.24), lineWidth: 1)
                Image(systemName: symbol)
                    .font(.system(size: max(8, size * (presentation.isTerminal ? 0.44 : 0.4)), weight: .semibold))
                    .foregroundStyle(bubbleTint)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(
                        .bounce,
                        options: .nonRepeating,
                        value: reduceMotion ? FleetUpdateBubblePresentation.pending : presentation
                    )
            }
            .frame(width: size, height: size)
            .scaleEffect(isActive ? 1.15 : 1)
        }
        .frame(width: size + 12, height: size + 12)
        .phaseAnimator(floatPhases) { content, phase in
            content.offset(
                x: phase.horizontalOffset * floatScale * 0.4,
                y: phase.verticalOffset * floatScale
            )
        } animation: { _ in
            Motion.updateBubbleDrift
        }
        .motionAwareAnimation(Motion.updateBubbleHandoff, value: presentation)
        .motionAwareAnimation(Motion.updateBubbleHandoff, value: isActive)
    }
}
