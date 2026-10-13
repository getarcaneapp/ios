import Arcane
import SwiftUI

/// Read-only task list. Used on its own and embedded in service, stack, and
/// node detail screens.
struct SwarmTasksView: View {
    enum Source: Hashable {
        case all
        case service(String)
        case stack(String)
        case node(String)
    }

    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutationStore
    let environmentID: EnvironmentID
    let source: Source

    @State private var list = EnvironmentPagedList<SwarmTaskSummary>(pageSize: 50)

    private var swarmVersion: Int { mutationStore.version(kind: .swarm, envID: environmentID) }

    var body: some View {
        SwarmListState(
            isLoading: list.isLoading,
            isEmpty: list.items.isEmpty,
            errorMessage: list.errorMessage,
            emptyTitle: "No Tasks",
            emptySystemImage: "checklist",
            retry: { Task { await load() } }
        ) {
            List {
                Section {
                    ForEach(list.items) { item in
                        SwarmTaskRow(task: item.value, showsService: source != .service(item.value.serviceId))
                    }
                    PaginatedListFooter(
                        hasMore: list.hasMore,
                        loadMoreError: list.loadMoreError,
                        onRetry: { Task { await loadMore() } },
                        onLoadMore: { Task { await loadMore() } }
                    )
                } header: {
                    ResourceCountSectionHeader(
                        "Tasks", loadedCount: list.items.count, totalCount: list.totalItems, hasMore: list.hasMore)
                }
            }
            .listStyle(.insetGrouped)
            .softTopScrollEdgeEffectCompat()
        }
        .modifier(SwarmTitleModifier(title: source == .all ? "Tasks" : nil))
        .task { await load() }
        .refreshable { await load() }
        .onChange(of: swarmVersion) { _, _ in
            Task { await load() }
        }
    }

    private func load() async {
        guard let client = manager.client else { return }
        await list.reload([ListEnvironment(id: environmentID, name: nil)], fetch: fetch(client: client))
    }

    private func loadMore() async {
        guard let client = manager.client else { return }
        await list.loadMore(fetch: fetch(client: client))
    }

    private func fetch(client: ArcaneClient) -> EnvironmentPagedList<SwarmTaskSummary>.Fetch {
        let source = source
        return { environmentID, start, limit in
            let response: PaginatedResponse<SwarmTaskSummary>
            switch source {
            case .all:
                response = try await client.swarm.listTasks(envID: environmentID, start: start, limit: limit)
            case .service(let id):
                response = try await client.swarm.serviceTasks(id, envID: environmentID, start: start, limit: limit)
            case .stack(let name):
                response = try await client.swarm.stackTasks(name, envID: environmentID, start: start, limit: limit)
            case .node(let id):
                response = try await client.swarm.nodeTasks(id, envID: environmentID, start: start, limit: limit)
            }
            return ResourcePage(items: response.data, pagination: response.pagination)
        }
    }
}

struct SwarmTaskRow: View {
    let task: SwarmTaskSummary
    var showsService = true

    private var title: String {
        if showsService, let slot = task.slot { return "\(task.serviceName).\(slot)" }
        if let slot = task.slot { return "Slot \(slot)" }
        return task.name.isEmpty ? String(task.id.prefix(12)) : task.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                SwarmStateBadge(state: task.currentState)
            }
            HStack(spacing: 12) {
                Label(
                    task.nodeName.isEmpty ? String(task.nodeId.prefix(12)) : task.nodeName, systemImage: "server.rack")
                if task.desiredState != task.currentState {
                    Label("Wants \(task.desiredState)", systemImage: "arrow.right.circle")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            if let error = task.error, !error.isEmpty {
                Text(verbatim: error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            Text(SwarmPresentation.date(task.updatedAt))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}
