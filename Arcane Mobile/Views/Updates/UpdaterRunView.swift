import SwiftUI
import Arcane

struct UpdaterRunView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    let environmentID: EnvironmentID

    private enum Phase: Equatable {
        case starting
        case running
        case completed(UpdaterResult)
        case failed(String)
    }

    @State private var phase: Phase = .starting
    @State private var liveStatus: UpdaterStatus?
    @State private var runTask: Task<Void, Never>?
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                switch phase {
                case .starting:
                    startingHero
                case .running:
                    runningHero
                    if let status = liveStatus {
                        countersCard(containers: Int(status.updatingContainers), projects: Int(status.updatingProjects))
                        if !status.containerIds.isEmpty {
                            idListCard(title: "Containers Updating", icon: "shippingbox.fill", tint: .blue, ids: status.containerIds)
                        }
                        if !status.projectIds.isEmpty {
                            idListCard(title: "Projects Updating", icon: "folder.fill", tint: .purple, ids: status.projectIds)
                        }
                    }
                case .completed(let result):
                    completedHero(result: result)
                    resultCountersCard(result: result)
                    if !result.items.isEmpty {
                        resultItemsCard(items: result.items)
                    }
                case .failed(let message):
                    ContentUnavailableView(
                        "Updater Failed",
                        systemImage: "exclamationmark.triangle",
                        description: Text(message)
                    )
                    .frame(maxWidth: .infinity, minHeight: 240)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Run Updater")
        .navigationBarTitleDisplayMode(.inline)
        .task { await start() }
        .onDisappear {
            pollTask?.cancel()
            runTask?.cancel()
        }
    }

    // MARK: - Hero cards

    private var startingHero: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.18))
                    .frame(width: 96, height: 96)
                ProgressView()
                    .controlSize(.large)
            }
            .glassEffectCompat(tint: Color.blue.opacity(0.25), in: .circle)
            VStack(spacing: 6) {
                Text("Starting…")
                    .font(.title2.bold())
                Text("Triggering updater")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 20)
        .glassEffectCompat(in: .rect(cornerRadius: 24))
    }

    private var runningHero: some View {
        let subtitle: String = {
            guard let status = liveStatus else { return "Working on it" }
            var parts: [String] = []
            if status.updatingContainers > 0 {
                parts.append("\(status.updatingContainers) container\(status.updatingContainers == 1 ? "" : "s")")
            }
            if status.updatingProjects > 0 {
                parts.append("\(status.updatingProjects) project\(status.updatingProjects == 1 ? "" : "s")")
            }
            return parts.isEmpty ? "Checking for updates" : parts.joined(separator: " · ") + " in progress"
        }()

        return VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.18))
                    .frame(width: 96, height: 96)
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(Color.blue)
                    .symbolEffect(.rotate, options: .repeating, isActive: true)
            }
            .glassEffectCompat(tint: Color.blue.opacity(0.25), in: .circle)
            VStack(spacing: 6) {
                Text("Running Updater")
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
        .glassEffectCompat(in: .rect(cornerRadius: 24))
    }

    private func completedHero(result: UpdaterResult) -> some View {
        let success = result.failed == 0
        let tint: Color = success ? .green : .orange
        let icon = success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        let title = success ? "Completed" : "Completed with Issues"
        let subtitle: String = {
            var parts: [String] = []
            parts.append("\(result.updated) updated")
            if result.failed > 0 { parts.append("\(result.failed) failed") }
            if result.skipped > 0 { parts.append("\(result.skipped) skipped") }
            parts.append("in \(result.duration)")
            return parts.joined(separator: " · ")
        }()

        return VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.18))
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
        .glassEffectCompat(in: .rect(cornerRadius: 24))
    }

    // MARK: - Counter cards

    private func countersCard(containers: Int, projects: Int) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            cardHeader(title: "In Progress", icon: "chart.bar.fill", tint: .purple)
            HStack(spacing: 12) {
                counterTile(label: "Containers", value: containers, icon: "shippingbox.fill", tint: .blue)
                counterTile(label: "Projects", value: projects, icon: "folder.fill", tint: .purple)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffectCompat(in: .rect(cornerRadius: 20))
    }

    private func resultCountersCard(result: UpdaterResult) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            cardHeader(title: "Summary", icon: "chart.bar.fill", tint: .purple)
            HStack(spacing: 12) {
                counterTile(label: "Checked", value: Int(result.checked), icon: "magnifyingglass", tint: .blue)
                counterTile(label: "Updated", value: Int(result.updated), icon: "checkmark.circle.fill", tint: .green)
            }
            HStack(spacing: 12) {
                counterTile(label: "Skipped", value: Int(result.skipped), icon: "minus.circle.fill", tint: .gray)
                counterTile(label: "Failed", value: Int(result.failed), icon: "xmark.circle.fill", tint: .red)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffectCompat(in: .rect(cornerRadius: 20))
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
        .background(tint.opacity(0.10), in: .rect(cornerRadius: 14))
    }

    private func idListCard(title: String, icon: String, tint: Color, ids: [String]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            cardHeader(title: title, icon: icon, tint: tint)
            VStack(spacing: 0) {
                ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(tint)
                            .symbolEffect(.rotate, options: .repeating, isActive: true)
                            .frame(width: 22, height: 22)
                            .background(tint.opacity(0.15), in: .circle)
                        Text(id)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 10)
                    if index < ids.count - 1 {
                        Divider()
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffectCompat(in: .rect(cornerRadius: 20))
    }

    // MARK: - Result item list

    private func resultItemsCard(items: [UpdaterResourceResult]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            cardHeader(title: "Resources (\(items.count))", icon: "list.bullet.rectangle.portrait", tint: .indigo)
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    UpdaterRunItemRow(item: item)
                        .padding(.vertical, 10)
                    if index < items.count - 1 {
                        Divider()
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffectCompat(in: .rect(cornerRadius: 20))
    }

    // MARK: - Header

    private func cardHeader(title: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.callout.weight(.semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(.headline)
            Spacer()
        }
    }

    // MARK: - Orchestration

    private func start() async {
        guard let client = manager.client else {
            phase = .failed("Not connected")
            return
        }
        guard runTask == nil else { return }

        phase = .starting
        liveStatus = nil

        let pollHandle = Task {
            await pollLoop(client: client)
        }
        pollTask = pollHandle

        let runHandle = Task {
            do {
                let result = try await client.updater.run(envID: environmentID)
                pollHandle.cancel()
                await MainActor.run {
                    phase = .completed(result)
                }
            } catch {
                pollHandle.cancel()
                let message = friendlyErrorMessage(error)
                await MainActor.run {
                    phase = .failed(message)
                }
            }
        }
        runTask = runHandle
    }

    private func pollLoop(client: ArcaneClient) async {
        // First tick: short delay so we transition to .running quickly.
        try? await Task.sleep(for: .milliseconds(400))
        if Task.isCancelled { return }
        await MainActor.run {
            if case .starting = phase { phase = .running }
        }

        while !Task.isCancelled {
            do {
                let status = try await client.updater.status(envID: environmentID)
                if Task.isCancelled { return }
                await MainActor.run {
                    liveStatus = status
                    if case .starting = phase { phase = .running }
                }
            } catch {
                // Swallow status-poll errors — the run task owns the authoritative outcome.
            }
            try? await Task.sleep(for: .milliseconds(1500))
        }
    }
}

private struct UpdaterRunItemRow: View {
    let item: UpdaterResourceResult

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: typeIcon)
                .font(.callout.weight(.semibold))
                .foregroundStyle(typeTint)
                .frame(width: 32, height: 32)
                .background(typeTint.opacity(0.15), in: .circle)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.resourceName ?? item.resourceId)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.resourceType.capitalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let imageChange {
                    Text(imageChange)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let error = item.error, !error.isEmpty {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            Text(statusText)
                .font(.caption2.weight(.bold))
                .foregroundStyle(statusTint)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(statusTint.opacity(0.15), in: .capsule)
        }
    }

    private var typeIcon: String {
        switch item.resourceType.lowercased() {
        case "container": return "shippingbox.fill"
        case "project", "stack": return "folder.fill"
        case "image": return "photo.stack.fill"
        default: return "arrow.triangle.2.circlepath"
        }
    }

    private var typeTint: Color {
        switch item.resourceType.lowercased() {
        case "container": return .blue
        case "project", "stack": return .purple
        case "image": return .pink
        default: return .gray
        }
    }

    private var statusText: String {
        if let error = item.error, !error.isEmpty { return "Failed" }
        if item.updateApplied == true { return "Updated" }
        if item.updateAvailable == true { return "Available" }
        return item.status.capitalized
    }

    private var statusTint: Color {
        if item.error?.isEmpty == false { return .red }
        if item.updateApplied == true { return .green }
        if item.updateAvailable == true { return .orange }
        switch item.status.lowercased() {
        case "skipped", "ignored", "up_to_date": return .gray
        case "failed", "error": return .red
        case "updated", "success": return .green
        default: return .blue
        }
    }

    private var imageChange: String? {
        let oldVersions = item.oldImages ?? [:]
        let newVersions = item.newImages ?? [:]
        guard let key = newVersions.keys.first ?? oldVersions.keys.first else { return nil }
        let oldTag = oldVersions[key]
        let newTag = newVersions[key]
        switch (oldTag, newTag) {
        case let (.some(old), .some(new)) where old != new: return "\(old) → \(new)"
        case let (.some(old), _): return old
        case let (_, .some(new)): return new
        default: return nil
        }
    }
}
