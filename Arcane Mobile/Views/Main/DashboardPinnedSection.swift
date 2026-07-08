import SwiftUI
import Arcane

struct DashboardPinnedSection: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(PinnedItemsStore.self) private var pinnedStore
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutationStore
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    let refreshToken: Int
    let onOpenContainer: (ContainerSummary) -> Void
    let onOpenProject: (ProjectDetails) -> Void

    @State private var containers: [ContainerSummary] = []
    @State private var projects: [ProjectDetails] = []
    @State private var isLoading = false
    @State private var runningID: String?
    @State private var loadGeneration = 0

    private var environmentID: EnvironmentID {
        manager.activeEnvironmentID
    }

    private var pinnedContainerIDs: Set<String> {
        pinnedStore.pinnedIDs(kind: .container, envID: environmentID)
    }

    private var pinnedProjectIDs: Set<String> {
        pinnedStore.pinnedIDs(kind: .project, envID: environmentID)
    }

    private var containerMutationVersion: Int {
        mutationStore.version(kind: .containers, envID: environmentID)
    }

    private var projectMutationVersion: Int {
        mutationStore.version(kind: .projects, envID: environmentID)
    }

    private var items: [DashboardPinnedItem] {
        containers.map(DashboardPinnedItem.container) + projects.map(DashboardPinnedItem.project)
    }

    var body: some View {
        Group {
            cardContent
        }
        .task { await reload() }
        .onChange(of: manager.activeEnvironmentID.rawValue) { _, _ in
            scheduleReload()
        }
        .onChange(of: pinnedStore.version) { _, _ in
            scheduleReload()
        }
        .onChange(of: containerMutationVersion) { _, _ in
            scheduleReload()
        }
        .onChange(of: projectMutationVersion) { _, _ in
            scheduleReload()
        }
        .onChange(of: refreshToken) { _, _ in
            scheduleReload()
        }
    }

    @ViewBuilder
    private var cardContent: some View {
        if !items.isEmpty || isLoading {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Pinned")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if isLoading {
                        ProgressView()
                            .scaleEffect(0.75)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 4)

                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    row(item)
                    if index < items.count - 1 {
                        Divider().padding(.leading, 54)
                    }
                }
            }
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dashboardCardBackground(cornerRadius: Radius.card)
            .motionAwareAnimation(Motion.reflow, value: items.map(\.id))
        }
    }

    private func row(_ item: DashboardPinnedItem) -> some View {
        HStack(spacing: 8) {
            Button {
                open(item)
            } label: {
                DashboardPinnedRowContent(item: item)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.pressable(scales: false))

            Button {
                Task { await runAction(for: item) }
            } label: {
                ZStack {
                    if runningID == item.id {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: item.actionSystemImage)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(item.actionTint)
                    }
                }
                .frame(width: 32, height: 32)
                .contentShape(Circle())
            }
            .buttonStyle(.pressable)
            .glassEffectCompat(interactive: true, in: .circle)
            .disabled(runningID != nil)
            .accessibilityLabel(item.actionTitle)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

}

private extension DashboardPinnedSection {
    func open(_ item: DashboardPinnedItem) {
        switch item {
        case .container(let container):
            onOpenContainer(container)
        case .project(let project):
            onOpenProject(project)
        }
    }

    func scheduleReload() {
        Task { await reload(refresh: true) }
    }

    func reload(refresh: Bool = false) async {
        guard manager.client != nil else { return }
        let requestedEnvironmentID = environmentID
        loadGeneration += 1
        let generation = loadGeneration
        if items.isEmpty { isLoading = true }
        defer {
            if loadGeneration == generation {
                isLoading = false
            }
        }

        let nextContainers = await loadPinnedContainers(
            envID: requestedEnvironmentID,
            generation: generation,
            refresh: refresh
        )
        let nextProjects = await loadPinnedProjects(
            envID: requestedEnvironmentID,
            generation: generation,
            refresh: refresh
        )
        guard loadGeneration == generation, requestedEnvironmentID == environmentID else { return }
        withAnimation(Motion.reduced(Motion.reflow, reduceMotion: reduceMotion)) {
            containers = nextContainers
            projects = nextProjects
        }
    }

    func loadPinnedContainers(
        envID: EnvironmentID,
        generation: Int,
        refresh: Bool
    ) async -> [ContainerSummary] {
        let pinned = pinnedStore.pinnedIDs(kind: .container, envID: envID)
        guard let client = manager.client, let cached = manager.cached, !pinned.isEmpty else { return [] }
        let path = client.rest.environmentPath(envID, "containers")
        do {
            let result: [ContainerSummary]? = try await cached.getList(
                path,
                elementType: ContainerSummary.self,
                policy: .containersList,
                envID: envID,
                refresh: refresh,
                onFresh: { fresh in
                    guard loadGeneration == generation, envID == environmentID else { return }
                    containers = fresh.filter { pinned.contains($0.id) }
                }
            )
            guard loadGeneration == generation, envID == environmentID else { return [] }
            return (result ?? []).filter { pinned.contains($0.id) }
        } catch {
            return []
        }
    }

    func loadPinnedProjects(
        envID: EnvironmentID,
        generation: Int,
        refresh: Bool
    ) async -> [ProjectDetails] {
        let pinned = pinnedStore.pinnedIDs(kind: .project, envID: envID)
        guard let client = manager.client, let cached = manager.cached, !pinned.isEmpty else { return [] }
        let query = SearchPaginationSort(start: 0, limit: 500)
        let base = client.rest.environmentPath(envID, "projects")
        let path = ArcaneAPIHelpers.queryPath(base, items: query.queryItems)
        do {
            let result: [ProjectDetails]? = try await cached.getListCustom(
                path: path,
                elementType: ProjectDetails.self,
                policy: .projects,
                envID: envID,
                refresh: refresh,
                onFresh: { fresh in
                    guard loadGeneration == generation, envID == environmentID else { return }
                    projects = fresh.filter { pinned.contains($0.id) }
                },
                fetcher: {
                    try await client.projects.list(envID: envID, query: query).data
                }
            )
            guard loadGeneration == generation, envID == environmentID else { return [] }
            return (result ?? []).filter { pinned.contains($0.id) }
        } catch {
            return []
        }
    }

    func runAction(for item: DashboardPinnedItem) async {
        guard let client = manager.client, runningID == nil else { return }
        runningID = item.id
        defer { runningID = nil }
        do {
            switch item {
            case .container(let container):
                if container.isRunning {
                    try await client.containers.stop(envID: environmentID, id: container.id)
                    showToast(.success("Container stopped"))
                } else {
                    try await client.containers.start(envID: environmentID, id: container.id)
                    showToast(.success("Container started"))
                }
                await invalidateContainerCaches()
                mutationStore.markChanged(kind: .containers, envID: environmentID)
            case .project(let project):
                if project.isDashboardRunning {
                    try await client.projects.down(envID: environmentID, projectID: project.id)
                    showToast(.success("Project stopped"))
                } else {
                    try await client.projects.deploy(envID: environmentID, projectID: project.id)
                    showToast(.success("Project deployed"))
                }
                await invalidateProjectCaches()
                mutationStore.markChanged(kind: .projects, envID: environmentID)
            }
            ReviewPrompter.shared.recordSuccess()
        } catch {
            showToast(.error(friendlyErrorMessage(error)))
        }
    }

    func invalidateContainerCaches() async {
        guard let cached = manager.cached, let client = manager.client else { return }
        await cached.invalidate(envID: environmentID, paths: [
            client.rest.environmentPath(environmentID, "containers"),
            client.rest.environmentPath(environmentID, "containers/*")
        ])
    }

    func invalidateProjectCaches() async {
        guard let cached = manager.cached, let client = manager.client else { return }
        await cached.invalidate(envID: environmentID, paths: [
            client.rest.environmentPath(environmentID, "projects") + "*",
            client.rest.environmentPath(environmentID, "projects/*")
        ])
    }
}

private enum DashboardPinnedItem: Identifiable {
    case container(ContainerSummary)
    case project(ProjectDetails)

    var id: String {
        switch self {
        case .container(let container): return "container-\(container.id)"
        case .project(let project): return "project-\(project.id)"
        }
    }

    var title: String {
        switch self {
        case .container(let container): return container.displayName
        case .project(let project): return project.displayName
        }
    }

    var status: String {
        switch self {
        case .container(let container): return container.isRunning ? "Running" : "Stopped"
        case .project(let project): return project.status.capitalized
        }
    }

    var isRunning: Bool {
        switch self {
        case .container(let container): return container.isRunning
        case .project(let project): return project.isDashboardRunning
        }
    }

    var icon: String {
        switch self {
        case .container: return "cube.box.fill"
        case .project: return "square.stack.3d.up.fill"
        }
    }

    var tint: Color {
        switch self {
        case .container: return .orange
        case .project: return .blue
        }
    }

    var actionTitle: String {
        switch self {
        case .container: return isRunning ? "Stop Container" : "Start Container"
        case .project: return isRunning ? "Stop Project" : "Deploy Project"
        }
    }

    var actionSystemImage: String {
        isRunning ? "stop.fill" : "play.fill"
    }

    var actionTint: Color {
        isRunning ? .red : .green
    }
}

private struct DashboardPinnedRowContent: View {
    let item: DashboardPinnedItem

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: item.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(item.tint, in: .circle)
                Circle()
                    .fill(item.isRunning ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 9, height: 9)
                    .offset(x: 1, y: 1)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(item.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption2.bold())
                .foregroundStyle(.secondary.opacity(0.5))
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.title): \(item.status)")
        .accessibilityAddTraits(.isButton)
    }
}

private extension ProjectDetails {
    var isDashboardRunning: Bool {
        status.lowercased() == "running"
    }
}
