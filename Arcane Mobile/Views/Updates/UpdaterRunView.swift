import SwiftUI
import Arcane

struct UpdaterRunSheet: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss

    let environments: [Arcane.Environment]
    let initialEnvironmentID: String?

    @State private var selectedEnvironmentID: String?

    init(
        environments: [Arcane.Environment],
        initialEnvironmentID: String? = nil
    ) {
        self.environments = environments
        self.initialEnvironmentID = initialEnvironmentID
        _selectedEnvironmentID = State(initialValue: initialEnvironmentID)
    }

    var body: some View {
        NavigationStack {
            if let selectedEnvironmentID {
                UpdaterRunView(
                    environmentID: EnvironmentID(rawValue: selectedEnvironmentID),
                    showsDismissButton: true
                )
                .id(selectedEnvironmentID)
            } else {
                environmentPicker
            }
        }
        .presentationDetents([.medium, .large])
        .presentationContentInteraction(.resizes)
        .presentationDragIndicator(.visible)
    }

    private var environmentPicker: some View {
        Group {
            if environments.isEmpty {
                ContentUnavailableView(
                    "No Environments",
                    systemImage: "server.rack",
                    description: Text("Add an environment before running the updater.")
                )
            } else {
                List {
                    Section {
                        ForEach(environments) { environment in
                            Button {
                                selectedEnvironmentID = environment.id
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(environment.displayName)
                                            .foregroundStyle(.primary)
                                        Text(environment.url)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    Spacer(minLength: 8)
                                    StatusBadge(status: environment.status)
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        }
                    } footer: {
                        Text("Pick an environment to run the container updater on.")
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Run Updater")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
    }
}

struct UpdaterRunView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(ImageUpdateCountStore.self) private var imageUpdateCountStore
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutationStore
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let environmentID: EnvironmentID
    var showsDismissButton = false

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
        GeometryReader { proxy in
            ScrollView {
                LazyVStack(spacing: 24) {
                    FleetUpdateScene(model: sceneModel)
                    phaseDetails
                }
                .frame(maxWidth: 680)
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
                .frame(minHeight: proxy.size.height, alignment: .center)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .navigationTitle("Run Updater")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsDismissButton {
                ToolbarItem(placement: .cancellationAction) {
                    Button(doneTitle) { dismiss() }
                }
            }
        }
        .interactiveDismissDisabled(phase == .starting)
        .task { await start() }
        .onDisappear {
            pollTask?.cancel()
            runTask?.cancel()
        }
    }

    // MARK: - Update scene

    private var sceneModel: FleetUpdateSceneModel {
        switch phase {
        case .starting:
            return FleetUpdateSceneModel(
                kind: .starting,
                title: "Starting the updater",
                subtitle: "Contacting the selected environment"
            )
        case .running:
            return FleetUpdateSceneModel(
                kind: .updating,
                title: "Updating containers",
                subtitle: runningSubtitle
            )
        case .completed(let result):
            return FleetUpdateSceneModel(
                kind: result.failed == 0 ? .completed : .warning,
                title: result.failed == 0 ? "Updater complete" : "Finished with issues",
                subtitle: completionSubtitle(result)
            )
        case .failed(let message):
            return FleetUpdateSceneModel(
                kind: .failed,
                title: "Updater failed",
                subtitle: message
            )
        }
    }

    @ViewBuilder
    private var phaseDetails: some View {
        switch phase {
        case .starting:
            EmptyView()
        case .running:
            if let status = liveStatus {
                countersCard(
                    containers: Int(status.updatingContainers),
                    projects: Int(status.updatingProjects)
                )
                if !status.containerIds.isEmpty {
                    idListCard(
                        title: "Containers Updating",
                        icon: "shippingbox.fill",
                        tint: .blue,
                        ids: status.containerIds
                    )
                }
                if !status.projectIds.isEmpty {
                    idListCard(
                        title: "Projects Updating",
                        icon: "folder.fill",
                        tint: .purple,
                        ids: status.projectIds
                    )
                }
            }
        case .completed(let result):
            resultCountersCard(result: result)
            if !result.items.isEmpty {
                resultItemsCard(items: result.items)
            }
        case .failed:
            Button {
                retry()
            } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    private var runningSubtitle: String {
        guard let status = liveStatus else { return "Checking for available updates" }
        var parts: [String] = []
        if status.updatingContainers > 0 {
            parts.append("\(status.updatingContainers) container\(status.updatingContainers == 1 ? "" : "s")")
        }
        if status.updatingProjects > 0 {
            parts.append("\(status.updatingProjects) project\(status.updatingProjects == 1 ? "" : "s")")
        }
        return parts.isEmpty ? "Checking for available updates" : parts.joined(separator: " · ") + " in progress"
    }

    private func completionSubtitle(_ result: UpdaterResult) -> String {
        var parts = ["\(result.updated) updated"]
        if result.failed > 0 { parts.append("\(result.failed) failed") }
        if result.skipped > 0 { parts.append("\(result.skipped) skipped") }
        parts.append("in \(result.duration)")
        return parts.joined(separator: " · ")
    }

    private var doneTitle: String {
        switch phase {
        case .completed, .failed: return "Done"
        case .starting, .running: return "Close"
        }
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
        .glassEffectCompat(in: .rect(cornerRadius: Radius.card))
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
        .glassEffectCompat(in: .rect(cornerRadius: Radius.card))
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
            Text(verbatim: String(value))
                .font(.system(.title, design: .rounded).bold())
                .foregroundStyle(.primary)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(tint.opacity(0.10), in: .rect(cornerRadius: Radius.standard))
    }

    private func idListCard(title: String, icon: String, tint: Color, ids: [String]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            cardHeader(title: title, icon: icon, tint: tint)
            VStack(spacing: 0) {
                ForEach(Array(ids.enumerated()), id: \.offset) { index, id in
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
        .glassEffectCompat(in: .rect(cornerRadius: Radius.card))
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
        .glassEffectCompat(in: .rect(cornerRadius: Radius.card))
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
                let result = try await RemoteDataLimits.runBoundedUpdater(
                    client: client,
                    environmentID: environmentID
                )
                await imageUpdateCountStore.refreshCount(
                    environmentID: environmentID,
                    client: client,
                    userID: manager.currentUser?.id
                )
                mutationStore.markChanged(kind: .images, envID: environmentID)
                pollHandle.cancel()
                await MainActor.run {
                    phase = .completed(result)
                    pollTask = nil
                    runTask = nil
                }
            } catch {
                pollHandle.cancel()
                let message = friendlyErrorMessage(error)
                await MainActor.run {
                    phase = .failed(message)
                    pollTask = nil
                    runTask = nil
                }
            }
        }
        runTask = runHandle
    }

    private func retry() {
        pollTask?.cancel()
        runTask?.cancel()
        pollTask = nil
        runTask = nil
        Task { await start() }
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
                let status = try await RemoteDataLimits.loadBoundedUpdaterStatus(
                    client: client,
                    environmentID: environmentID
                )
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
