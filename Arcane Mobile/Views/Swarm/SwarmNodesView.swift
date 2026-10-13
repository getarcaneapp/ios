import Arcane
import SwiftUI

/// Node actions shared by the list and the detail screen.
private enum SwarmNodeAction {
    case promote, demote
    case availability(String)

    var successTitle: String {
        switch self {
        case .promote: "Node promoted"
        case .demote: "Node demoted"
        case .availability(let value): "Node set to \(value)"
        }
    }

    @MainActor
    func perform(on node: SwarmNode, client: ArcaneClient, environmentID: EnvironmentID) async throws {
        switch self {
        case .promote: try await client.swarm.promoteNode(node.id, envID: environmentID)
        case .demote: try await client.swarm.demoteNode(node.id, envID: environmentID)
        case .availability(let value):
            try await client.swarm.updateNode(
                node.id, SwarmNodeUpdateRequest(availability: value), envID: environmentID)
        }
    }
}

extension SwarmNode {
    var isManager: Bool { role.lowercased() == "manager" }
    var isLeader: Bool { managerStatus?.lowercased() == "leader" }
}

struct SwarmNodesView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutationStore
    let environmentID: EnvironmentID

    @State private var list = EnvironmentPagedList<SwarmNode>(pageSize: 50)
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var pendingRemove: SwarmNode?

    private var swarmVersion: Int { mutationStore.version(kind: .swarm, envID: environmentID) }
    private var canManage: Bool { manager.permissions.has(Permission.Swarm.nodes, in: environmentID) }

    var body: some View {
        SwarmListState(
            isLoading: list.isLoading,
            isEmpty: list.items.isEmpty,
            errorMessage: list.errorMessage,
            emptyTitle: debouncedSearchText.isEmpty ? "No Nodes" : "No Results",
            emptySystemImage: "server.rack",
            retry: { Task { await load() } }
        ) {
            List {
                Section {
                    ForEach(list.items) { item in
                        nodeLink(item.value)
                    }
                    PaginatedListFooter(
                        hasMore: list.hasMore,
                        loadMoreError: list.loadMoreError,
                        onRetry: { Task { await loadMore() } },
                        onLoadMore: { Task { await loadMore() } }
                    )
                } header: {
                    ResourceCountSectionHeader(
                        "Nodes", loadedCount: list.items.count, totalCount: list.totalItems, hasMore: list.hasMore)
                }
            }
            .listStyle(.insetGrouped)
            .softTopScrollEdgeEffectCompat()
        }
        .navigationTitle("Nodes")
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search nodes")
        .debounce(searchText, for: .milliseconds(200), into: $debouncedSearchText)
        .task { await load() }
        .refreshable { await load() }
        .onChange(of: debouncedSearchText) { _, _ in
            Task { await load() }
        }
        .onChange(of: swarmVersion) { _, _ in
            Task { await load() }
        }
        .deleteConfirmation(item: $pendingRemove) { node in
            DeleteConfirmationConfig(
                title: "Remove Node",
                message: "Force-remove “\(node.hostname)” from the swarm? Its tasks are rescheduled elsewhere.",
                icon: "trash",
                actions: [
                    DeleteConfirmationAction(title: "Remove") {
                        Task { await remove(node) }
                    }
                ]
            )
        }
    }

    private func nodeLink(_ node: SwarmNode) -> some View {
        NavigationLink {
            SwarmNodeDetailView(node: node, environmentID: environmentID)
        } label: {
            SwarmNodeRow(node: node)
        }
        .contextMenu {
            if canManage {
                if node.isManager {
                    Button {
                        Task { await run(.demote, on: node) }
                    } label: {
                        Label("Demote to Worker", systemImage: "arrow.down.circle")
                    }
                } else {
                    Button {
                        Task { await run(.promote, on: node) }
                    } label: {
                        Label("Promote to Manager", systemImage: "arrow.up.circle")
                    }
                }
                SwarmAvailabilityMenu(current: node.availability) { value in
                    Task { await run(.availability(value), on: node) }
                }
                Button(role: .destructive) {
                    pendingRemove = node
                } label: {
                    DestructiveLabel(text: "Remove")
                }
                .tint(.red)
            }
        }
    }

    private func run(_ action: SwarmNodeAction, on node: SwarmNode) async {
        guard let client = manager.client else { return }
        do {
            try await action.perform(on: node, client: client, environmentID: environmentID)
            await manager.swarmChanged(environmentID, mutationStore: mutationStore)
            showToast(.success(action.successTitle))
        } catch {
            showToast(.error(friendlyErrorMessage(error)))
        }
    }

    private func remove(_ node: SwarmNode) async {
        guard let client = manager.client else { return }
        do {
            try await client.swarm.deleteNode(node.id, force: true, envID: environmentID)
            list.update { $0.removeAll { $0.value.id == node.id } }
            await manager.swarmChanged(environmentID, mutationStore: mutationStore)
            showToast(.success("Node removed"))
        } catch {
            showToast(.error(friendlyErrorMessage(error)))
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

    private func fetch(client: ArcaneClient) -> EnvironmentPagedList<SwarmNode>.Fetch {
        let search = debouncedSearchText.isEmpty ? nil : debouncedSearchText
        return { environmentID, start, limit in
            let response = try await client.swarm.listNodes(
                envID: environmentID, search: search, start: start, limit: limit)
            return ResourcePage(items: response.data, pagination: response.pagination)
        }
    }
}

private struct SwarmAvailabilityMenu: View {
    let current: String
    let onSelect: (String) -> Void

    var body: some View {
        Menu {
            ForEach(["active", "pause", "drain"], id: \.self) { value in
                Button {
                    onSelect(value)
                } label: {
                    if current.lowercased() == value {
                        Label(value.capitalized, systemImage: "checkmark")
                    } else {
                        Text(value.capitalized)
                    }
                }
                .disabled(current.lowercased() == value)
            }
        } label: {
            Label("Availability", systemImage: "slider.horizontal.below.square.and.square.filled")
        }
    }
}

struct SwarmNodeRow: View {
    let node: SwarmNode

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: node.isManager ? "crown.fill" : "server.rack")
                .font(.title3)
                .foregroundStyle(node.isLeader ? .yellow : .accentColor)
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: node.hostname)
                    .lineLimit(1)
                Text(
                    [node.isLeader ? "Leader" : node.role.capitalized, node.address, node.engineVersion]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                SwarmStateBadge(state: node.status)
                if node.availability.lowercased() != "active" {
                    SwarmStateBadge(state: node.availability)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct SwarmNodeDetailView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutationStore
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let environmentID: EnvironmentID

    @State private var node: SwarmNode
    @State private var showAddLabel = false
    @State private var newLabelKey = ""
    @State private var newLabelValue = ""
    @State private var runningActionID: String?

    init(node: SwarmNode, environmentID: EnvironmentID) {
        self.environmentID = environmentID
        _node = State(initialValue: node)
    }

    private var canManage: Bool { manager.permissions.has(Permission.Swarm.nodes, in: environmentID) }
    private var swarmVersion: Int { mutationStore.version(kind: .swarm, envID: environmentID) }

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: node.isManager ? "crown.fill" : "server.rack")
                        .font(.title)
                        .foregroundStyle(node.isLeader ? .yellow : .accentColor)
                        .frame(width: 52, height: 52)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: node.hostname)
                            .font(.title3.bold())
                        Text(node.isLeader ? "Leader" : node.role.capitalized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            SwarmStateBadge(state: node.status)
                            SwarmStateBadge(state: node.availability)
                        }
                    }
                }
            }
            Section("Details") {
                LabeledContent("ID") { MonospacedValue(value: String(node.id.prefix(12))) }
                if let address = node.address, !address.isEmpty {
                    LabeledContent("Address") { MonospacedValue(value: address) }
                }
                if let reachability = node.reachability, !reachability.isEmpty {
                    LabeledContent("Reachability") { SwarmStateBadge(state: reachability) }
                }
                if let managerAddress = node.managerAddress, !managerAddress.isEmpty {
                    LabeledContent("Manager Address") { MonospacedValue(value: managerAddress) }
                }
                if let engine = node.engineVersion, !engine.isEmpty {
                    LabeledContent("Engine", value: engine)
                }
                if let platform = node.platform, !platform.isEmpty {
                    LabeledContent("Platform", value: platform)
                }
                LabeledContent("Created", value: SwarmPresentation.date(node.createdAt))
                LabeledContent("Updated", value: SwarmPresentation.date(node.updatedAt))
                NavigationLink {
                    SwarmTasksView(environmentID: environmentID, source: .node(node.id))
                        .navigationTitle("Tasks on \(node.hostname)")
                } label: {
                    Label("Tasks", systemImage: "checklist")
                }
            }
            labelsSection
            agentSection
        }
        .listStyle(.insetGrouped)
        .softTopScrollEdgeEffectCompat()
        .navigationTitle(node.hostname)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await reload() }
        .onChange(of: swarmVersion) { _, _ in
            Task { await reload() }
        }
        .resourceActionsToolbar(
            primary: canManage ? roleAction : nil,
            secondary: canManage ? availabilityActions : [],
            overflow: canManage ? [removeAction] : [],
            runningItemID: runningActionID,
            isDisabled: runningActionID != nil,
            resourceName: node.hostname,
            active: canManage
        )
        .alert("Add Label", isPresented: $showAddLabel) {
            TextField("Key", text: $newLabelKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Value", text: $newLabelValue)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Add") {
                let key = newLabelKey.trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty else { return }
                var labels = node.labels ?? [:]
                labels[key] = newLabelValue
                Task { await saveLabels(labels) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var labelsSection: some View {
        Section {
            let labels = (node.labels ?? [:]).sorted { $0.key < $1.key }
            ForEach(labels, id: \.key) { label in
                LabeledContent(label.key) {
                    Text(verbatim: label.value)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if canManage {
                        Button {
                            var updated = node.labels ?? [:]
                            updated.removeValue(forKey: label.key)
                            Task { await saveLabels(updated) }
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                        .tint(.red)
                    }
                }
            }
            if canManage {
                Button {
                    newLabelKey = ""
                    newLabelValue = ""
                    showAddLabel = true
                } label: {
                    Label("Add Label", systemImage: "plus")
                }
            }
        } header: {
            Text("Labels")
        } footer: {
            if canManage, !(node.labels ?? [:]).isEmpty {
                Text("Swipe a label to remove it.")
            }
        }
    }

    @ViewBuilder
    private var agentSection: some View {
        let agent = node.agent
        Section {
            LabeledContent("State") { SwarmStateBadge(state: agent.state.rawValue) }
            if let environmentName = agent.environmentName, !environmentName.isEmpty {
                LabeledContent("Environment", value: environmentName)
            }
            if let kind = agent.bindingKind {
                LabeledContent("Binding", value: kind.rawValue.capitalized)
            }
            if let heartbeat = agent.lastHeartbeat {
                LabeledContent("Last Heartbeat", value: SwarmPresentation.date(heartbeat))
            }
        } header: {
            Text("Arcane Agent")
        } footer: {
            Text("Pair node agents from Arcane on the web.")
        }
    }

    private var roleAction: ActionButtonItem {
        if node.isManager {
            return ActionButtonItem(
                id: "demote", title: "Demote", systemImage: "arrow.down.circle", tint: .orange,
                confirmationMessage: "Demote this manager to a worker."
            ) {
                Task { await run(.demote, id: "demote") }
            }
        }
        return ActionButtonItem(id: "promote", title: "Promote", systemImage: "arrow.up.circle", tint: .accentColor) {
            Task { await run(.promote, id: "promote") }
        }
    }

    private var availabilityActions: [ActionButtonItem] {
        [("active", "play.circle"), ("pause", "pause.circle"), ("drain", "arrow.down.to.line.circle")]
            .filter { $0.0 != node.availability.lowercased() }
            .map { value, image in
                ActionButtonItem(
                    id: value, title: value == "active" ? "Activate" : value.capitalized, systemImage: image,
                    tint: value == "drain" ? .orange : .accentColor
                ) {
                    Task { await run(.availability(value), id: value) }
                }
            }
    }

    private var removeAction: ActionButtonItem {
        ActionButtonItem(
            id: "remove", title: "Remove", systemImage: "trash", tint: .red, role: .destructive,
            confirmationMessage: "Force-remove this node from the swarm. Its tasks are rescheduled elsewhere."
        ) {
            Task { await remove() }
        }
    }

    private func run(_ action: SwarmNodeAction, id: String) async {
        guard let client = manager.client else { return }
        runningActionID = id
        defer { runningActionID = nil }
        do {
            try await action.perform(on: node, client: client, environmentID: environmentID)
            await manager.swarmChanged(environmentID, mutationStore: mutationStore)
            showToast(.success(action.successTitle))
        } catch {
            showToast(.error(friendlyErrorMessage(error)))
        }
    }

    private func saveLabels(_ labels: [String: String]) async {
        guard let client = manager.client else { return }
        do {
            try await client.swarm.updateNode(node.id, SwarmNodeUpdateRequest(labels: labels), envID: environmentID)
            await manager.swarmChanged(environmentID, mutationStore: mutationStore)
            showToast(.success("Labels updated"))
        } catch {
            showToast(.error(friendlyErrorMessage(error)))
        }
    }

    private func remove() async {
        guard let client = manager.client else { return }
        runningActionID = "remove"
        defer { runningActionID = nil }
        do {
            try await client.swarm.deleteNode(node.id, force: true, envID: environmentID)
            await manager.swarmChanged(environmentID, mutationStore: mutationStore)
            showToast(.success("Node removed"))
            dismiss()
        } catch {
            showToast(.error(friendlyErrorMessage(error)))
        }
    }

    private func reload() async {
        guard let client = manager.client else { return }
        if let fresh = try? await client.swarm.node(node.id, envID: environmentID) {
            node = fresh
        }
    }
}
