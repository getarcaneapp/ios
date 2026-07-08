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
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

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
    @State private var finishPulse = false

    /// The manager environment. The server ignores the path segment for these
    /// endpoints — the manager always orchestrates the whole fleet.
    private let managerEnvID = EnvironmentID(rawValue: "0")

    private var isAdmin: Bool { manager.currentUser?.isAdmin == true }

    /// Collapses the phase to a coarse step so the blur-replace transition only
    /// fires on real phase changes, not on every 3s poll payload refresh.
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
                VStack(spacing: 20) {
                    if !isAdmin {
                        ContentUnavailableView(
                            "Admins Only",
                            systemImage: "lock.shield",
                            description: Text("Updating all environments requires an administrator account.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 240)
                    } else {
                        phaseContent
                            .motionAwareAnimation(Motion.state, value: phaseKey)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
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
        switch phase {
        case .loading:
            loadingCard
                .transition(.blurReplace)
        case .ready(let lastJob):
            readyContent(lastJob: lastJob)
                .transition(.blurReplace)
        case .triggering:
            progressHero(title: "Starting…", subtitle: "Contacting the manager")
                .transition(.blurReplace)
        case .polling(let job):
            runningContent(job: job, reconnecting: false)
                .transition(.blurReplace)
        case .reconnecting(let job):
            runningContent(job: job, reconnecting: true)
                .transition(.blurReplace)
        case .finished(let job, let note):
            finishedContent(job: job, note: note)
                .transition(.blurReplace)
        case .unsupported(let message):
            ContentUnavailableView(
                "Not Available",
                systemImage: "lock.shield",
                description: Text(message)
            )
            .frame(maxWidth: .infinity, minHeight: 240)
            .transition(.blurReplace)
        case .failed(let message):
            VStack(spacing: 20) {
                ContentUnavailableView(
                    "Update All Failed",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
                .frame(maxWidth: .infinity, minHeight: 240)
                retryButton
            }
            .transition(.blurReplace)
        }
    }

    private var doneTitle: String {
        if case .finished = phase { return "Done" }
        return "Close"
    }

    // MARK: - Ready (confirmation step)

    private func readyContent(lastJob: EnvironmentUpdateJob?) -> some View {
        VStack(spacing: 16) {
            heroCard(
                tint: .blue,
                icon: "arrow.up.circle.fill",
                title: "Update All Environments",
                subtitle: environmentCount == 1
                    ? "1 environment · latest release"
                    : "\(environmentCount) environments · latest release"
            )

            stepsCard

            if let lastJob {
                lastRunRow(job: lastJob)
            }

            Button(role: .destructive) {
                Task { await trigger() }
            } label: {
                Label("Update All", systemImage: "arrow.up.circle.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
    }

    /// The old paragraph card, compressed into three glanceable steps.
    private var stepsCard: some View {
        VStack(spacing: 0) {
            stepRow(icon: "server.rack", tint: .blue, text: "Agents update first")
            Divider().padding(.leading, 44)
            stepRow(icon: "crown.fill", tint: .indigo, text: "Manager restarts last")
            Divider().padding(.leading, 44)
            stepRow(icon: "wifi.slash", tint: .orange, text: "Brief disconnect at the end")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .glassEffectCompat(in: .rect(cornerRadius: Radius.card))
    }

    private func stepRow(icon: String, tint: Color, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.12), in: .circle)
            Text(text)
                .font(.subheadline)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
    }

    private func lastRunRow(job: EnvironmentUpdateJob) -> some View {
        HStack(spacing: 12) {
            Image(systemName: job.status == .completed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(job.status == .completed ? Color.green : .orange)
                .frame(width: 32, height: 32)
                .background((job.status == .completed ? Color.green : .orange).opacity(0.12), in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text("Last run")
                    .font(.subheadline)
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
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .glassEffectCompat(in: .rect(cornerRadius: Radius.card))
    }

    private func lastRunSummary(job: EnvironmentUpdateJob) -> String {
        if job.status == .failed {
            return job.error ?? "Failed"
        }
        let results = job.results ?? []
        let updated = results.filter { $0.status == .updated || $0.status == .triggered }.count
        let failed = results.filter { $0.status == .failed }.count
        let skipped = results.filter { $0.status == .skippedOffline }.count
        var parts = ["\(updated) updated"]
        if failed > 0 { parts.append("\(failed) failed") }
        if skipped > 0 { parts.append("\(skipped) skipped") }
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
    private func runningContent(job: EnvironmentUpdateJob, reconnecting: Bool) -> some View {
        VStack(spacing: 20) {
            if reconnecting {
                reconnectingHero
            } else if job.status == .pendingRestart {
                restartingHero
            } else {
                updatingHero(job: job)
            }
            if let results = job.results, !results.isEmpty {
                resultsCard(results: results)
                    .motionAwareAnimation(Motion.reflow, value: results.map(\.status))
            }
        }
    }

    /// Rotating symbol wrapped in a live progress ring that fills as
    /// environments complete.
    private func updatingHero(job: EnvironmentUpdateJob) -> some View {
        let results = job.results ?? []
        let done = results.filter {
            $0.status == .updated || $0.status == .triggered
                || $0.status == .skippedOffline || $0.status == .failed
        }.count
        let fraction = results.isEmpty ? 0 : Double(done) / Double(results.count)
        let subtitle = results.isEmpty
            ? "Working on it"
            : "\(done) of \(results.count) done"

        return VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.14))
                Circle()
                    .stroke(Color.blue.opacity(0.15), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(Color.blue, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .motionAwareAnimation(Motion.gauge, value: fraction)
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(Color.blue)
                    .symbolEffect(.rotate, options: .repeating, isActive: !reduceMotion)
            }
            .frame(width: 96, height: 96)
            .glassEffectCompat(tint: Color.blue.opacity(0.25), in: .circle)
            VStack(spacing: 6) {
                Text("Updating")
                    .font(.title2.bold())
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .motionAwareAnimation(Motion.state, value: subtitle)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 20)
        .glassEffectCompat(in: .rect(cornerRadius: Radius.hero))
    }

    private var restartingHero: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.14))
                    .frame(width: 96, height: 96)
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(Color.blue)
                    .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !reduceMotion)
            }
            .glassEffectCompat(tint: Color.blue.opacity(0.25), in: .circle)
            VStack(spacing: 6) {
                Text("Restarting Manager")
                    .font(.title2.bold())
                Text("Agents are done · connection may drop")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 20)
        .glassEffectCompat(in: .rect(cornerRadius: Radius.hero))
    }

    private var reconnectingHero: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.14))
                    .frame(width: 96, height: 96)
                Image(systemName: "wifi")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(Color.orange)
                    .symbolEffect(.variableColor.iterative.reversing, options: .repeating, isActive: !reduceMotion)
            }
            .glassEffectCompat(tint: Color.orange.opacity(0.25), in: .circle)
            VStack(spacing: 6) {
                Text("Reconnecting")
                    .font(.title2.bold())
                Text("Waiting for the manager")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 20)
        .glassEffectCompat(in: .rect(cornerRadius: Radius.hero))
    }

    // MARK: - Finished

    @ViewBuilder
    private func finishedContent(job: EnvironmentUpdateJob, note: String?) -> some View {
        let results = job.results ?? []
        let updated = results.filter { $0.status == .updated || $0.status == .triggered }.count
        let failed = results.filter { $0.status == .failed }.count
        let skipped = results.filter { $0.status == .skippedOffline }.count

        let tint: Color = {
            if job.status == .failed { return .red }
            if note != nil || failed > 0 || skipped > 0 { return .orange }
            return .green
        }()
        let icon = tint == .green ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        let title: String = {
            if job.status == .failed { return "Update Failed" }
            if note != nil { return "Manager Restarting" }
            return failed > 0 || skipped > 0 ? "Done, with Issues" : "All Updated"
        }()
        let subtitle = note ?? (job.status == .failed
            ? (job.error ?? "The fleet update failed.")
            : lastRunSummary(job: job))

        VStack(spacing: 20) {
            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(tint.opacity(0.16))
                        .frame(width: 96, height: 96)
                    Image(systemName: icon)
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(tint)
                        .symbolEffect(.bounce, options: .nonRepeating, value: finishPulse)
                }
                .glassEffectCompat(tint: tint.opacity(0.25), in: .circle)
                VStack(spacing: 6) {
                    Text(title)
                        .font(.title2.bold())
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .padding(.horizontal, 20)
            .glassEffectCompat(in: .rect(cornerRadius: Radius.hero))
            .onAppear {
                if !reduceMotion { finishPulse.toggle() }
            }

            HStack(spacing: 12) {
                counterTile(label: "Updated", value: updated, icon: "checkmark.circle.fill", tint: .green)
                counterTile(label: "Failed", value: failed, icon: "xmark.circle.fill", tint: .red)
                counterTile(label: "Skipped", value: skipped, icon: "minus.circle.fill", tint: .gray)
            }

            if !results.isEmpty {
                resultsCard(results: results)
            }
        }
    }

    private func counterTile(label: String, value: Int, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text("\(value)")
                .font(.system(.title, design: .rounded).bold())
                .foregroundStyle(.primary)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(tint.opacity(0.10), in: .rect(cornerRadius: Radius.standard))
    }

    // MARK: - Results list

    private func resultsCard(results: [EnvironmentUpdateResult]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                FleetUpdateResultRow(result: result)
                    .padding(.vertical, 10)
                if index < results.count - 1 {
                    Divider().padding(.leading, 44)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .glassEffectCompat(in: .rect(cornerRadius: Radius.card))
    }

    // MARK: - Shared cards

    private var loadingCard: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Checking status…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .padding(.vertical, 24)
        .padding(.horizontal, 20)
        .glassEffectCompat(in: .rect(cornerRadius: Radius.hero))
    }

    private func progressHero(title: String, subtitle: String) -> some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.14))
                    .frame(width: 96, height: 96)
                ProgressView()
                    .controlSize(.large)
            }
            .glassEffectCompat(tint: Color.blue.opacity(0.25), in: .circle)
            VStack(spacing: 6) {
                Text(title)
                    .font(.title2.bold())
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 20)
        .glassEffectCompat(in: .rect(cornerRadius: Radius.hero))
    }

    private func heroCard(tint: Color, icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.16))
                    .frame(width: 96, height: 96)
                Image(systemName: icon)
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .glassEffectCompat(tint: tint.opacity(0.25), in: .circle)
            VStack(spacing: 6) {
                Text(title)
                    .font(.title2.bold())
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 20)
        .glassEffectCompat(in: .rect(cornerRadius: Radius.hero))
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
            let job = try await client.system.triggerUpdateAll(envID: managerEnvID)
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

// MARK: - Row

private struct FleetUpdateResultRow: View {
    let result: EnvironmentUpdateResult

    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isManager: Bool { result.environmentId == "0" }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isManager ? "crown.fill" : "server.rack")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(isManager ? Color.indigo : .blue)
                .frame(width: 32, height: 32)
                .background((isManager ? Color.indigo : .blue).opacity(0.12), in: .circle)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(result.environmentName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if isManager {
                        Text("Manager")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15), in: .capsule)
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
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(statusTint.opacity(0.15), in: .capsule)
            .motionAwareAnimation(Motion.state, value: result.status)
        }
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
        case .updated, .triggered: return .green
        case .skippedOffline: return .gray
        case .failed: return .red
        case .unknown: return .blue
        }
    }
}
