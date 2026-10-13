import Arcane
import SwiftUI

/// Swarm services, either every service or the services in one stack.
struct SwarmServicesView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutationStore
    let environmentID: EnvironmentID
    /// Limits the list to one stack (embedded in stack detail).
    var stackName: String? = nil

    @State private var list = EnvironmentPagedList<SwarmServiceSummary>(pageSize: 50)
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var showCreate = false
    @State private var scaleTarget: SwarmServiceSummary?
    @State private var logsTarget: SwarmServiceSummary?
    @State private var pendingDelete: SwarmServiceSummary?

    private var swarmVersion: Int { mutationStore.version(kind: .swarm, envID: environmentID) }
    private var canManage: Bool { manager.permissions.has(Permission.Swarm.services, in: environmentID) }
    private var canReadLogs: Bool { manager.permissions.has(Permission.Swarm.servicesLogs, in: environmentID) }

    var body: some View {
        SwarmListState(
            isLoading: list.isLoading,
            isEmpty: list.items.isEmpty,
            errorMessage: list.errorMessage,
            emptyTitle: debouncedSearchText.isEmpty ? "No Services" : "No Results",
            emptySystemImage: "shippingbox",
            retry: { Task { await load() } }
        ) {
            List {
                Section {
                    ForEach(list.items) { item in
                        serviceLink(item.value)
                    }
                    PaginatedListFooter(
                        hasMore: list.hasMore,
                        loadMoreError: list.loadMoreError,
                        onRetry: { Task { await loadMore() } },
                        onLoadMore: { Task { await loadMore() } }
                    )
                } header: {
                    ResourceCountSectionHeader(
                        "Services", loadedCount: list.items.count, totalCount: list.totalItems,
                        hasMore: list.hasMore)
                }
            }
            .listStyle(.insetGrouped)
            .softTopScrollEdgeEffectCompat()
        }
        .modifier(SwarmTitleModifier(title: stackName == nil ? "Services" : nil))
        .modifier(SwarmSearchModifier(enabled: stackName == nil, text: $searchText, prompt: "Search services"))
        .debounce(searchText, for: .milliseconds(200), into: $debouncedSearchText)
        .toolbar {
            if stackName == nil, canManage {
                AppToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showCreate = true
                    } label: {
                        Image(systemName: "plus")
                            .appAccentToolbarSymbol()
                    }
                    .accessibilityLabel("Create Service")
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .onChange(of: debouncedSearchText) { _, _ in
            Task { await load() }
        }
        .onChange(of: swarmVersion) { _, _ in
            Task { await load() }
        }
        .sheet(isPresented: $showCreate) {
            SwarmServiceEditorView(environmentID: environmentID, existing: nil)
        }
        .sheet(item: $scaleTarget) { service in
            SwarmScaleSheet(service: service, environmentID: environmentID)
        }
        .fullScreenCover(item: $logsTarget) { service in
            LogsView(
                title: service.name,
                logStream: {
                    manager.client?.boundedSwarmServiceLogs(
                        envID: environmentID, serviceID: service.id, timestamps: true)
                }
            )
        }
        .deleteConfirmation(item: $pendingDelete) { service in
            DeleteConfirmationConfig(
                title: "Delete Service",
                message: "Delete “\(service.name)”? Its tasks are stopped and removed.",
                icon: "trash",
                actions: [
                    DeleteConfirmationAction(title: "Delete") {
                        Task { await delete(service) }
                    }
                ]
            )
        }
    }

    private func serviceLink(_ service: SwarmServiceSummary) -> some View {
        NavigationLink {
            SwarmServiceDetailView(serviceID: service.id, summary: service, environmentID: environmentID)
        } label: {
            SwarmServiceRow(service: service, showsStack: stackName == nil)
        }
        .contextMenu {
            if canManage, service.mode == "replicated" {
                Button {
                    scaleTarget = service
                } label: {
                    Label("Scale", systemImage: "plusminus")
                }
            }
            if canReadLogs {
                Button {
                    logsTarget = service
                } label: {
                    Label("Logs", systemImage: "text.alignleft")
                }
            }
            if canManage {
                Button(role: .destructive) {
                    pendingDelete = service
                } label: {
                    DestructiveLabel(text: "Delete")
                }
                .tint(.red)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if canManage {
                Button {
                    pendingDelete = service
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(.red)
            }
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

    private func fetch(client: ArcaneClient) -> EnvironmentPagedList<SwarmServiceSummary>.Fetch {
        let search = debouncedSearchText.isEmpty ? nil : debouncedSearchText
        let stackName = stackName
        return { environmentID, start, limit in
            let response =
                if let stackName {
                    try await client.swarm.stackServices(
                        stackName, envID: environmentID, start: start, limit: limit)
                } else {
                    try await client.swarm.listServices(
                        envID: environmentID, search: search, start: start, limit: limit)
                }
            return ResourcePage(items: response.data, pagination: response.pagination)
        }
    }

    private func delete(_ service: SwarmServiceSummary) async {
        guard let client = manager.client else { return }
        do {
            try await client.swarm.deleteService(service.id, envID: environmentID)
            list.update { $0.removeAll { $0.value.id == service.id } }
            await manager.swarmChanged(environmentID, mutationStore: mutationStore)
            showToast(.success("Service deleted"))
        } catch {
            showToast(.error(friendlyErrorMessage(error)))
        }
    }
}

/// `.searchable` only on the standalone list; embedded lists share their parent's bar.
struct SwarmSearchModifier: ViewModifier {
    let enabled: Bool
    @Binding var text: String
    let prompt: String

    func body(content: Content) -> some View {
        if enabled {
            content.searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: prompt)
        } else {
            content
        }
    }
}

struct SwarmServiceRow: View {
    let service: SwarmServiceSummary
    var showsStack = true

    private var isHealthy: Bool {
        service.mode != "replicated" || service.runningReplicas >= service.replicas
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox.fill")
                .font(.title3)
                .foregroundStyle(isHealthy ? Color.accentColor : .orange)
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: service.name)
                    .font(.body)
                    .lineLimit(1)
                Text(verbatim: service.image)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if showsStack, let stack = service.stackName, !stack.isEmpty {
                    Label(stack, systemImage: "square.stack.3d.up")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(verbatim: "\(service.runningReplicas)/\(service.replicas)")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(isHealthy ? .green : .orange)
                Text(service.mode.capitalized)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Replica count editor for replicated services.
struct SwarmScaleSheet: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutationStore
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let service: SwarmServiceSummary
    let environmentID: EnvironmentID

    @State private var replicas: Int
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(service: SwarmServiceSummary, environmentID: EnvironmentID) {
        self.service = service
        self.environmentID = environmentID
        _replicas = State(initialValue: Int(service.replicas))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $replicas, in: 0...1_000) {
                        LabeledContent("Replicas") {
                            Text(verbatim: String(replicas))
                                .font(.body.monospacedDigit())
                        }
                    }
                } footer: {
                    Text(verbatim: "\(service.runningReplicas) of \(service.replicas) running now.")
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }
            }
            .navigationTitle("Scale \(service.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                AppToolbarItem(placement: .confirmationAction) {
                    Button("Scale") {
                        Task { await scale() }
                    }
                    .disabled(isSaving || replicas == Int(service.replicas))
                }
            }
            .interactiveDismissDisabled(isSaving)
        }
        .presentationDetents([.medium])
    }

    private func scale() async {
        guard let client = manager.client else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let response = try await client.swarm.scaleService(
                service.id, replicas: UInt64(max(0, replicas)), envID: environmentID)
            await manager.swarmChanged(environmentID, mutationStore: mutationStore)
            showToast(.success("Scaled to \(replicas) replica\(replicas == 1 ? "" : "s")"))
            if let warning = response.warnings?.first { showToast(.info(warning)) }
            dismiss()
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }
}
