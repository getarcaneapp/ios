import Arcane
import SwiftUI

struct SwarmStacksView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutationStore
    let environmentID: EnvironmentID

    @State private var list = EnvironmentPagedList<SwarmStackSummary>(pageSize: 50)
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var showCreate = false
    @State private var pendingDelete: SwarmStackSummary?

    private var swarmVersion: Int { mutationStore.version(kind: .swarm, envID: environmentID) }
    private var canManage: Bool { manager.permissions.has(Permission.Swarm.stacks, in: environmentID) }

    var body: some View {
        SwarmListState(
            isLoading: list.isLoading,
            isEmpty: list.items.isEmpty,
            errorMessage: list.errorMessage,
            emptyTitle: debouncedSearchText.isEmpty ? "No Stacks" : "No Results",
            emptySystemImage: "square.stack.3d.up",
            retry: { Task { await load() } }
        ) {
            List {
                Section {
                    ForEach(list.items) { item in
                        stackLink(item.value)
                    }
                    PaginatedListFooter(
                        hasMore: list.hasMore,
                        loadMoreError: list.loadMoreError,
                        onRetry: { Task { await loadMore() } },
                        onLoadMore: { Task { await loadMore() } }
                    )
                } header: {
                    ResourceCountSectionHeader(
                        "Stacks", loadedCount: list.items.count, totalCount: list.totalItems, hasMore: list.hasMore)
                }
            }
            .listStyle(.insetGrouped)
            .softTopScrollEdgeEffectCompat()
        }
        .navigationTitle("Stacks")
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search stacks")
        .debounce(searchText, for: .milliseconds(200), into: $debouncedSearchText)
        .toolbar {
            if canManage {
                AppToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showCreate = true
                    } label: {
                        Image(systemName: "plus")
                            .appAccentToolbarSymbol()
                    }
                    .accessibilityLabel("Deploy Stack")
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
            SwarmStackEditorView(environmentID: environmentID, stackName: nil)
        }
        .deleteConfirmation(item: $pendingDelete) { stack in
            DeleteConfirmationConfig(
                title: "Delete Stack",
                message: "Delete “\(stack.name)” and remove its services?",
                icon: "trash",
                actions: [
                    DeleteConfirmationAction(title: "Delete") {
                        Task { await delete(stack) }
                    }
                ]
            )
        }
    }

    private func stackLink(_ stack: SwarmStackSummary) -> some View {
        NavigationLink {
            SwarmStackDetailView(name: stack.name, environmentID: environmentID)
        } label: {
            HStack(spacing: 12) {
                RowIcon(systemImage: "square.stack.3d.up.fill")
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: stack.name)
                    Text(verbatim: "\(stack.services) service\(stack.services == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(SwarmPresentation.date(stack.updatedAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .contextMenu {
            if canManage {
                Button(role: .destructive) {
                    pendingDelete = stack
                } label: {
                    DestructiveLabel(text: "Delete")
                }
                .tint(.red)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if canManage {
                Button {
                    pendingDelete = stack
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

    private func fetch(client: ArcaneClient) -> EnvironmentPagedList<SwarmStackSummary>.Fetch {
        let search = debouncedSearchText.isEmpty ? nil : debouncedSearchText
        return { environmentID, start, limit in
            let response = try await client.swarm.listStacks(
                envID: environmentID, search: search, start: start, limit: limit)
            return ResourcePage(items: response.data, pagination: response.pagination)
        }
    }

    private func delete(_ stack: SwarmStackSummary) async {
        guard let client = manager.client else { return }
        do {
            try await client.swarm.deleteStack(stack.name, envID: environmentID)
            list.update { $0.removeAll { $0.value.id == stack.id } }
            await manager.swarmChanged(environmentID, mutationStore: mutationStore)
            showToast(.success("Stack deleted"))
        } catch {
            showToast(.error(friendlyErrorMessage(error)))
        }
    }
}

struct SwarmStackDetailView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutationStore
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let name: String
    let environmentID: EnvironmentID

    @State private var selectedTab: Tab = .services
    @State private var source: SwarmStackSource?
    @State private var sourceError: String?
    @State private var showEdit = false
    @State private var runningActionID: String?

    private enum Tab: String, CaseIterable, Identifiable {
        case services, tasks, source
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var systemImage: String {
            switch self {
            case .services: "shippingbox.fill"
            case .tasks: "checklist"
            case .source: "doc.text"
            }
        }
        var tint: Color {
            switch self {
            case .services: .blue
            case .tasks: .purple
            case .source: .teal
            }
        }
    }

    private var canManage: Bool { manager.permissions.has(Permission.Swarm.stacks, in: environmentID) }
    private var tabs: [Tab] { Tab.allCases.filter { $0 != .source || canManage } }

    var body: some View {
        VStack(spacing: 0) {
            ScrollableTabBar(
                selection: $selectedTab,
                options: tabs.map {
                    ScrollableTabOption($0, title: $0.title, systemImage: $0.systemImage, tint: $0.tint)
                },
                accessibilityLabel: "Stack detail sections"
            )
            switch selectedTab {
            case .services:
                SwarmServicesView(environmentID: environmentID, stackName: name)
            case .tasks:
                SwarmTasksView(environmentID: environmentID, source: .stack(name))
            case .source:
                sourceView
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .resourceActionsToolbar(
            primary: canManage
                ? ActionButtonItem(id: "edit", title: "Edit", systemImage: "pencil", tint: .accentColor) {
                    showEdit = true
                } : nil,
            overflow: canManage
                ? [
                    ActionButtonItem(
                        id: "delete",
                        title: "Delete",
                        systemImage: "trash",
                        tint: .red,
                        role: .destructive,
                        confirmationMessage: "This removes every service in the stack."
                    ) {
                        Task { await delete() }
                    }
                ] : [],
            runningItemID: runningActionID,
            isDisabled: runningActionID != nil,
            resourceName: name,
            active: canManage
        )
        .sheet(isPresented: $showEdit) {
            SwarmStackEditorView(environmentID: environmentID, stackName: name)
        }
    }

    @ViewBuilder
    private var sourceView: some View {
        Group {
            if let source {
                List {
                    Section("compose.yaml") {
                        Text(verbatim: source.composeContent)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    if let env = source.envContent, !env.isEmpty {
                        Section(".env") {
                            Text(verbatim: env)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            } else if let sourceError {
                ContentUnavailableView {
                    Label("Source Unavailable", systemImage: "doc.text")
                } description: {
                    Text(sourceError)
                } actions: {
                    Button("Try Again") { Task { await loadSource() } }
                }
            } else {
                ArcaneLoadingView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await loadSource() }
    }

    private func loadSource() async {
        guard let client = manager.client else { return }
        do {
            source = try await client.swarm.stackSource(name, envID: environmentID)
            sourceError = nil
        } catch {
            sourceError = friendlyErrorMessage(error)
        }
    }

    private func delete() async {
        guard let client = manager.client else { return }
        runningActionID = "delete"
        defer { runningActionID = nil }
        do {
            try await client.swarm.deleteStack(name, envID: environmentID)
            await manager.swarmChanged(environmentID, mutationStore: mutationStore)
            showToast(.success("Stack deleted"))
            dismiss()
        } catch {
            showToast(.error(friendlyErrorMessage(error)))
        }
    }
}

/// Deploy a new stack or edit an existing stack's compose / .env source.
struct SwarmStackEditorView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutationStore
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let environmentID: EnvironmentID
    /// nil deploys a new stack.
    let stackName: String?

    @State private var previewSession = ComposePreviewSession()
    @State private var name = ""
    @State private var compose = ""
    @State private var environment = ""
    @State private var originalCompose = ""
    @State private var originalEnvironment = ""
    @State private var prune = false
    @State private var withRegistryAuth = false
    @State private var resolveImage = "always"
    @State private var redeploy = true
    @State private var isLoaded = false
    @State private var isSaving = false
    @State private var isValidating = false
    @State private var validation: SwarmStackRenderConfigResponse?
    @State private var errorMessage: String?
    @State private var confirmDiscard = false

    private var isEditing: Bool { stackName != nil }
    private var hasChanges: Bool {
        compose != originalCompose || environment != originalEnvironment || (!isEditing && !name.isEmpty)
    }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool {
        isLoaded && !compose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !trimmedName.isEmpty
            && (!isEditing || hasChanges || redeploy)
    }

    var body: some View {
        NavigationStack {
            Form {
                if isLoaded {
                    if !isEditing {
                        Section("Stack") {
                            FormTextField(
                                title: "Name", placeholder: "my-stack", text: $name,
                                autocapitalization: .never, autocorrectionDisabled: true)
                        }
                    }
                    Section("Files") {
                        NavigationLink("Compose file") { fileEditor(isEnvironment: false) }
                        NavigationLink("Environment variables") { fileEditor(isEnvironment: true) }
                        Button {
                            Task { await validate() }
                        } label: {
                            HStack {
                                Label("Validate", systemImage: "checkmark.seal")
                                if isValidating {
                                    Spacer()
                                    ProgressView().controlSize(.small)
                                }
                            }
                        }
                        .disabled(isValidating || compose.isEmpty)
                    }
                    if let validation {
                        validationSection(validation)
                    }
                    Section {
                        if isEditing {
                            Toggle("Redeploy After Saving", isOn: $redeploy)
                        }
                        if !isEditing || redeploy {
                            Toggle("Prune Removed Services", isOn: $prune)
                            Toggle("Send Registry Auth", isOn: $withRegistryAuth)
                            Picker("Resolve Image", selection: $resolveImage) {
                                Text("Always").tag("always")
                                Text("Changed").tag("changed")
                                Text("Never").tag("never")
                            }
                        }
                    } header: {
                        Text("Deploy")
                    }
                } else if errorMessage == nil {
                    ArcaneLoadingView("Loading stack…")
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                        if !isLoaded { Button("Try Again") { Task { await load() } } }
                    }
                }
            }
            .disabled(isSaving)
            .navigationTitle(isEditing ? "Edit \(stackName ?? "")" : "Deploy Stack")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if hasChanges { confirmDiscard = true } else { dismiss() }
                    }
                    .disabled(isSaving)
                }
                AppToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? (redeploy ? "Deploy" : "Save") : "Deploy") {
                        Task { await save() }
                    }
                    .disabled(!canSave || isSaving)
                }
            }
            .deleteConfirmation(
                isPresented: $confirmDiscard,
                config: DeleteConfirmationConfig(
                    title: "Discard stack changes?",
                    actions: [DeleteConfirmationAction(title: "Discard Changes") { dismiss() }],
                    cancelTitle: "Keep Editing",
                    dismissOnConfirm: false
                )
            )
            .interactiveDismissDisabled(hasChanges || isSaving)
            .task { if !isLoaded { await load() } }
        }
    }

    @ViewBuilder
    private func fileEditor(isEnvironment: Bool) -> some View {
        Group {
            if previewSession.isEnabled {
                if isEnvironment {
                    EnvPreviewEditor(text: $environment, readOnly: isSaving)
                } else {
                    ComposePreviewEditor(text: $compose, readOnly: isSaving)
                }
            } else {
                CodeEditorView(
                    text: isEnvironment ? $environment : $compose,
                    language: isEnvironment ? .env : .yaml, readOnly: isSaving)
            }
        }
        .navigationTitle(isEnvironment ? ".env" : "compose.yaml")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func validationSection(_ result: SwarmStackRenderConfigResponse) -> some View {
        Section("Validation") {
            Label(
                "\(result.services.count) service\(result.services.count == 1 ? "" : "s"), "
                    + "\(result.networks.count) network\(result.networks.count == 1 ? "" : "s"), "
                    + "\(result.volumes.count) volume\(result.volumes.count == 1 ? "" : "s")",
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)
            ForEach(result.warnings ?? [], id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
        }
    }

    private func load() async {
        guard let stackName else {
            isLoaded = true
            return
        }
        guard let client = manager.client else { return }
        errorMessage = nil
        do {
            let source = try await client.swarm.stackSource(stackName, envID: environmentID)
            name = stackName
            compose = source.composeContent
            environment = source.envContent ?? ""
            originalCompose = compose
            originalEnvironment = environment
            isLoaded = true
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func validate() async {
        guard let client = manager.client else { return }
        isValidating = true
        errorMessage = nil
        defer { isValidating = false }
        do {
            validation = try await client.swarm.renderStackConfig(
                SwarmStackRenderConfigRequest(
                    name: trimmedName.isEmpty ? "stack" : trimmedName,
                    composeContent: compose,
                    envContent: environment.isEmpty ? nil : environment
                ),
                envID: environmentID
            )
        } catch {
            validation = nil
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func save() async {
        guard let client = manager.client, canSave else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        let envContent = environment.isEmpty ? nil : environment
        do {
            if let stackName, hasChanges {
                _ = try await client.swarm.updateStackSource(
                    stackName,
                    SwarmStackSourceUpdateRequest(composeContent: compose, envContent: envContent),
                    envID: environmentID
                )
            }
            if !isEditing || redeploy {
                _ = try await client.swarm.deployStack(
                    SwarmStackDeployRequest(
                        name: trimmedName,
                        composeContent: compose,
                        envContent: envContent,
                        withRegistryAuth: withRegistryAuth,
                        prune: prune,
                        resolveImage: resolveImage
                    ),
                    envID: environmentID
                )
            }
            await manager.swarmChanged(environmentID, mutationStore: mutationStore)
            showToast(.success(!isEditing || redeploy ? "Stack deployed" : "Stack saved"))
            dismiss()
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }
}
