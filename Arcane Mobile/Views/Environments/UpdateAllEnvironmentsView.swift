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
    @Namespace private var resultIconNamespace

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
        NavigationStack {
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
            }
            .background(Color(uiColor: .systemBackground).ignoresSafeArea())
            .navigationTitle("Update All")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(doneTitle) { dismiss() }
                }
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
                FleetUpdateScene(model: sceneModel, iconNamespace: resultIconNamespace)

                Group {
                    phaseDetails
                }
                .transition(.opacity)
                .motionAwareAnimation(Motion.state, value: phaseKey)
            }
            .motionAwareAnimation(Motion.reflow, value: sceneModel.ringEnvironments.map(\.id))
            .motionAwareAnimation(Motion.updateBubbleHandoff, value: sceneModel.activeEnvironment?.id)
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
        case .polling(let job), .reconnecting(let job):
            runningDetails(job: job)
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
                ringEnvironments: job.isTerminal ? [] : ringModels(for: results)
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

    // MARK: - Running

    @ViewBuilder
    private func runningDetails(job: EnvironmentUpdateJob) -> some View {
        let orderedResults = resultsInProcessingOrder(job.results ?? [])
        let results = orderedResults.filter { isCompletedResult($0) }
        if !results.isEmpty {
            resultsTimeline(results: results)
                .motionAwareAnimation(Motion.reflow, value: results.map(\.status))
        }
    }

    // MARK: - Finished

    @ViewBuilder
    private func finishedDetails(job: EnvironmentUpdateJob) -> some View {
        let results = resultsInProcessingOrder(job.results ?? [])
        let displayedResults = job.isTerminal
            ? results
            : results.filter { isCompletedResult($0) }
        let counts = resultCounts(results)

        VStack(spacing: 24) {
            metricsStrip(updated: counts.updated, failed: counts.failed, skipped: counts.skipped)

            if !displayedResults.isEmpty {
                resultsTimeline(results: displayedResults)
            }
        }
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

    // MARK: - Results timeline

    private func resultsTimeline(results: [EnvironmentUpdateResult]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Results")
                    .font(.headline)
                Spacer(minLength: 12)
                Text(verbatim: String(results.count))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.bottom, 10)
            Divider()
            ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                FleetUpdateResultRow(result: result, iconNamespace: resultIconNamespace)
                    .padding(.vertical, 14)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                if index < results.count - 1 {
                    Divider().padding(.leading, 44)
                }
            }
        }
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
        results.enumerated().compactMap { index, result in
            guard !isCompletedResult(result) else { return nil }
            return FleetUpdateRingEnvironment(
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
                phase = .ready(lastJob: job)
            } else {
                // A job is already running (started here earlier, or from the
                // web UI) — resume watching it instead of offering a new run.
                phase = .polling(job)
                startPolling(client: client, lastKnown: job)
            }
        } catch ArcaneError.notFound {
            // No job has ever run. (Also what an old server without the
            // endpoint returns — the POST disambiguates.)
            phase = .ready(lastJob: nil)
        } catch ArcaneError.decoding {
            phase = .ready(lastJob: nil)
        } catch {
            phase = .failed(friendlyErrorMessage(error))
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

private enum FleetUpdateSceneKind: Equatable {
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

private struct FleetUpdateRingEnvironment: Identifiable, Equatable {
    let result: EnvironmentUpdateResult
    let slotIndex: Int
    let totalCount: Int

    var id: String { result.id }
}

private struct FleetUpdateSceneModel: Equatable {
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

private struct FleetUpdateScene: View {
    let model: FleetUpdateSceneModel
    let iconNamespace: Namespace.ID

    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var focusSize: CGFloat = 152
    @State private var hasAppeared = false
    @State private var completionPulse = 0

    var body: some View {
        VStack(spacing: 28) {
            focus

            VStack(spacing: 6) {
                Text(model.title)
                    .font(.largeTitle.weight(.bold))
                    .multilineTextAlignment(.center)
                    .contentTransition(.interpolate)

                Text(model.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.interpolate)
                    .motionAwareAnimation(Motion.state, value: model.subtitle)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 248)
        .padding(.vertical, 4)
        .background {
            RadialGradient(
                colors: [model.kind.tint.opacity(0.13), model.kind.tint.opacity(0.035), .clear],
                center: .center,
                startRadius: 0,
                endRadius: 108
            )
            .frame(width: 320, height: 240)
            .blur(radius: 8)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .opacity(hasAppeared ? 1 : 0)
        .scaleEffect(reduceMotion || hasAppeared ? 1 : 0.94)
        .motionAwareAnimation(Motion.updateStage, value: model.kind)
        .motionAwareAnimation(Motion.updateStage, value: model.title)
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

    private var focus: some View {
        ZStack {
            Circle()
                .fill(model.kind.tint.opacity(0.055))
                .scaleEffect(model.kind.isTerminal ? 1.07 : 1)

            Circle()
                .stroke(model.kind.tint.opacity(0.14), lineWidth: 1)
                .scaleEffect(model.kind.isTerminal ? 1.07 : 1)

            Circle()
                .stroke(Color.secondary.opacity(0.12), lineWidth: 5)

            Circle()
                .trim(from: 0, to: model.ringFraction)
                .stroke(
                    model.kind.tint,
                    style: StrokeStyle(lineWidth: 5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .opacity(model.ringFraction == 0 ? 0 : 1)
                .animation(Motion.gauge, value: model.ringFraction)

            animatedSymbol
                .opacity(model.showsPercentage || model.showsActiveEnvironment ? 0 : 1)
                .scaleEffect(model.showsPercentage || model.showsActiveEnvironment ? 0.82 : 1)

            Text(verbatim: "\(model.percentage)%")
                .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                .contentTransition(.numericText())
                .opacity(model.showsPercentage ? 1 : 0)
                .scaleEffect(model.showsPercentage ? 1 : 0.82)
                .motionAwareAnimation(Motion.updateStage, value: model.percentage)

            if !model.ringEnvironments.isEmpty {
                FleetUpdateRingEnvironments(
                    environments: model.ringEnvironments,
                    activeEnvironmentID: model.activeEnvironment?.id,
                    tint: model.kind.tint,
                    iconNamespace: iconNamespace,
                    ringDiameter: min(focusSize, 172)
                )
                .transition(.opacity)
            }
        }
        .frame(width: min(focusSize, 172), height: min(focusSize, 172))
        .motionAwareAnimation(Motion.updateStage, value: model.showsPercentage)
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

private struct FleetUpdateRingEnvironments: View {
    let environments: [FleetUpdateRingEnvironment]
    let activeEnvironmentID: String?
    let tint: Color
    let iconNamespace: Namespace.ID
    let ringDiameter: CGFloat

    private var activeEnvironment: EnvironmentUpdateResult? {
        environments.first { $0.id == activeEnvironmentID }?.result
    }

    var body: some View {
        ZStack {
            if let activeEnvironment {
                VStack(spacing: 3) {
                    Text(activeEnvironment.environmentName)
                        .font(.caption.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .truncationMode(.middle)

                    Text("Updating")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: ringDiameter * 0.56)
                .id(activeEnvironment.id)
                .transition(.opacity)
            }

            ForEach(environments) { environment in
                FleetUpdateRingBubble(
                    environment: environment,
                    isActive: environment.id == activeEnvironmentID,
                    tint: tint,
                    iconNamespace: iconNamespace,
                    ringDiameter: ringDiameter
                )
            }
        }
        .frame(width: ringDiameter, height: ringDiameter)
        .accessibilityHidden(true)
    }
}

private struct FleetUpdateRingBubble: View {
    let environment: FleetUpdateRingEnvironment
    let isActive: Bool
    let tint: Color
    let iconNamespace: Namespace.ID
    let ringDiameter: CGFloat

    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .headline) private var activeIconSize: CGFloat = 48

    private var isManager: Bool { environment.result.environmentId == "0" }

    private var animationPhases: [FleetUpdateBubblePhase] {
        reduceMotion || !isActive ? [.resting] : FleetUpdateBubblePhase.allCases
    }

    private var angle: Double {
        let slotCount = max(environment.totalCount, 1)
        return -.pi / 2
            + Double(environment.slotIndex) / Double(slotCount) * 2 * .pi
    }

    private var ringOffset: CGSize {
        let radius = ringDiameter / 2
        return CGSize(
            width: CGFloat(cos(angle)) * radius,
            height: CGFloat(sin(angle)) * radius
        )
    }

    private var inactiveIconSize: CGFloat {
        let circumference = ringDiameter * .pi
        let slotCount = CGFloat(max(environment.totalCount, 1))
        return min(28, max(10, circumference * 0.76 / slotCount))
    }

    private var bubbleSize: CGFloat {
        isActive ? min(activeIconSize, 56) : inactiveIconSize
    }

    private var cutoutSize: CGFloat {
        bubbleSize + (isActive ? 8 : 6)
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(uiColor: .systemBackground))
                .frame(width: cutoutSize, height: cutoutSize)

            ZStack {
                Circle()
                    .fill(tint.opacity(isActive ? 0.18 : 0.10))
                Circle()
                    .stroke(tint.opacity(isActive ? 0.42 : 0.22), lineWidth: 1)
                Image(systemName: isManager ? "crown.fill" : "server.rack")
                    .font(.system(size: max(7, bubbleSize * 0.38), weight: .semibold))
                    .foregroundStyle(tint)
                    .opacity(isActive || bubbleSize >= 16 ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .frame(width: bubbleSize, height: bubbleSize)
        }
        .frame(width: cutoutSize, height: cutoutSize)
        .phaseAnimator(animationPhases) { content, phase in
            content
                .offset(x: phase.horizontalOffset, y: phase.verticalOffset)
                .scaleEffect(phase.scale)
        } animation: { _ in
            Motion.updateBubbleDrift
        }
        .motionAwareAnimation(Motion.updateBubbleHandoff, value: isActive)
        .offset(x: ringOffset.width, y: ringOffset.height)
        .matchedGeometryEffect(id: environment.id, in: iconNamespace)
        .zIndex(isActive ? 2 : 1)
    }
}

// MARK: - Row

private struct FleetUpdateResultRow: View {
    let result: EnvironmentUpdateResult
    let iconNamespace: Namespace.ID

    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isManager: Bool { result.environmentId == "0" }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isManager ? "crown.fill" : "server.rack")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(isManager ? Color.indigo : .blue)
                .frame(width: 32, height: 32)
                .background((isManager ? Color.indigo : .blue).opacity(0.12), in: .circle)
                .matchedGeometryEffect(id: result.id, in: iconNamespace)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(result.environmentName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if isManager {
                        Text("Manager")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                if let versionChange {
                    Text(versionChange)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let error = result.error, !error.isEmpty {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                if result.status == .updating {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption2.weight(.bold))
                        .symbolEffect(.rotate, options: .repeating, isActive: !reduceMotion)
                }
                Text(statusText)
                    .font(.caption2.weight(.bold))
                    .contentTransition(.interpolate)
            }
            .foregroundStyle(statusTint)
            .motionAwareAnimation(Motion.state, value: result.status)
        }
        .accessibilityElement(children: .combine)
    }

    /// Hide digest-style versions — they read as noise at row size.
    private var versionChange: String? {
        let from = displayable(result.fromVersion)
        let to = displayable(result.toVersion)
        switch (from, to) {
        case let (.some(from), .some(to)) where from != to:
            return "\(from) → \(to)"
        case let (.some(from), .none):
            return from
        case let (.none, .some(to)):
            return to
        default:
            return from
        }
    }

    private func displayable(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, !raw.contains(":"), raw.count <= 20 else { return nil }
        return raw
    }

    private var statusText: String {
        switch result.status {
        case .pending: return "Pending"
        case .updating: return "Updating"
        case .updated: return "Updated"
        case .upToDate: return "Up to Date"
        case .triggered: return "Triggered"
        case .skippedOffline: return "Offline"
        case .failed: return "Failed"
        case .unknown: return "Unknown"
        }
    }

    private var statusTint: Color {
        switch result.status {
        case .pending: return .gray
        case .updating: return .blue
        case .updated, .upToDate, .triggered: return .green
        case .skippedOffline: return .gray
        case .failed: return .red
        case .unknown: return .blue
        }
    }
}
