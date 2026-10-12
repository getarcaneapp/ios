import Arcane
import SwiftUI

struct DynamicResourceListView: View {
    private static let pageSize = 50

    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(EnvironmentsStore.self) private var environmentsStore

    let title: String
    let systemImage: String
    /// The list endpoint in an environment. Global resources ignore the environment.
    let path: (EnvironmentID, ArcaneClient) -> String
    /// The environment an environment-scoped list loads from; nil for global resources.
    var environmentID: EnvironmentID? = nil
    /// All Environments preview: list and act on resources from every enabled
    /// environment. Only applies to environment-scoped lists.
    var allEnvironments = false
    var emptyTitle: String? = nil
    var actions: [BackendListAction] = []
    var createTitle: String? = nil
    var createFields: [BackendFormField] = []
    var createPath: ((EnvironmentID, ArcaneClient) -> String)? = nil
    var managementDestination: AppTab? = nil
    /// Replaces the generic detail page for a row. Receives the row and a
    /// callback that reloads the list after the page changes the resource.
    var detailDestination: ((EnvironmentItem<DynamicResource>, @escaping () -> Void) -> AnyView)? = nil

    @State private var list = EnvironmentPagedList<DynamicResource>(pageSize: Self.pageSize)
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var actionMessage: String?
    @State private var selectedAction: PendingAction?
    @State private var showCreateSheet = false
    @State private var createEnvironmentID: EnvironmentID?
    @State private var displayedItems: [EnvironmentItem<DynamicResource>] = []

    private var items: [EnvironmentItem<DynamicResource>] { list.items }

    /// Global resources load once through the active environment's client;
    /// their path ignores it.
    private var baseEnvironmentID: EnvironmentID { environmentID ?? manager.activeEnvironmentID }

    private var showsAllEnvironments: Bool { allEnvironments && environmentID != nil }

    /// The environments this list covers, known before the first load finishes.
    private var listEnvironments: [ListEnvironment] {
        showsAllEnvironments ? list.environments : [ListEnvironment(id: baseEnvironmentID, name: nil)]
    }

    private func computeDisplayedItems() -> [EnvironmentItem<DynamicResource>] {
        items
            .filter { item in
                debouncedSearchText.isEmpty || item.title.localizedCaseInsensitiveContains(debouncedSearchText)
                    || item.subtitle.localizedCaseInsensitiveContains(debouncedSearchText)
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private func rebuildDisplayedItems() {
        displayedItems = computeDisplayedItems()
    }

    var body: some View {
        Group {
            if list.isLoading && items.isEmpty {
                ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage = list.errorMessage, items.isEmpty {
                ContentUnavailableView {
                    Label("Couldn't Load \(title)", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try Again") { Task { await load() } }
                }
            } else if items.isEmpty {
                ContentUnavailableView(emptyTitle ?? "No \(title)", systemImage: systemImage)
            } else {
                List {
                    EnvironmentLoadFailuresSection(failures: list.failedEnvironments) {
                        Task { await load() }
                    }
                    if let actionMessage {
                        Section {
                            Label(actionMessage, systemImage: "checkmark.circle")
                                .foregroundStyle(.green)
                        }
                    }
                    Section {
                        ForEach(displayedItems) { item in
                            NavigationLink {
                                detailView(for: item)
                            } label: {
                                DynamicResourceRow(
                                    item: item.value, systemImage: systemImage, environmentName: item.environmentName
                                )
                                .rowEnvironment(item)
                            }
                            .contextMenu {
                                ForEach(actionsForRow()) { action in
                                    Button(role: action.destructive ? .destructive : nil) {
                                        selectedAction = PendingAction(action: action, item: item)
                                    } label: {
                                        backendActionLabel(action)
                                    }
                                    .tint(action.destructive ? Color.red : nil)
                                }
                            }
                        }

                        PaginatedListFooter(
                            hasMore: list.hasMore,
                            loadMoreError: list.loadMoreError,
                            onRetry: { Task { await loadMore() } },
                            onLoadMore: { Task { await loadMore() } }
                        )
                    } header: {
                        ResourceCountSectionHeader(
                            title,
                            loadedCount: items.count,
                            totalCount: list.totalItems,
                            hasMore: list.hasMore
                        )
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle(title)
        .searchable(
            text: $searchText, placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search \(title.lowercased())"
        )
        .debounce(searchText, for: .milliseconds(200), into: $debouncedSearchText)
        .onChange(of: debouncedSearchText) {
            rebuildDisplayedItems()
            Task { await load() }
        }
        .toolbar {
            AppToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh")
            }
            if let managementDestination {
                AppToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink {
                        appTabDestination(
                            managementDestination,
                            manager: manager,
                            selectedTab: .constant("")
                        )
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Manage \(managementDestination.title)")
                }
            }
            if createPath != nil, !createFields.isEmpty {
                if #available(iOS 26, *) {
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                }
                AppToolbarItem(placement: .navigationBarTrailing) {
                    if showsAllEnvironments {
                        EnvironmentActionButton(
                            title: createTitle ?? "Create", systemImage: "plus", environments: listEnvironments
                        ) { environmentID in
                            createEnvironmentID = environmentID
                            showCreateSheet = true
                        }
                    } else {
                        Button {
                            createEnvironmentID = nil
                            showCreateSheet = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel(createTitle ?? "Create")
                    }
                }
            }
            let globalActions = actions.filter { !$0.requiresSelection }
            if !globalActions.isEmpty {
                AppToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        ForEach(globalActions) { action in
                            Button(role: action.destructive ? .destructive : nil) {
                                selectedAction = PendingAction(action: action, item: nil)
                            } label: {
                                backendActionLabel(action)
                            }
                            .tint(action.destructive ? Color.red : nil)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("More options")
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .alert(
            selectedAction?.action.title ?? "Run Action",
            isPresented: Binding(
                get: { selectedAction != nil },
                set: { if !$0 { selectedAction = nil } }
            )
        ) {
            if let selectedAction {
                Button(selectedAction.action.title, role: selectedAction.action.destructive ? .destructive : nil) {
                    Task { await run(selectedAction) }
                }
            }
            Button("Cancel", role: .cancel) { selectedAction = nil }
        } message: {
            if let selectedAction {
                Text(
                    selectedAction.item.map { "\(selectedAction.action.title) \($0.title)?" }
                        ?? "\(selectedAction.action.title)?")
            }
        }
        .sheet(isPresented: $showCreateSheet) {
            if let createPath {
                let createEnvironment = createEnvironmentID ?? baseEnvironmentID
                DynamicCreateFormView(
                    title: createTitle ?? "Create \(title)",
                    fields: createFields
                ) { data in
                    guard let client = manager.client else { return }
                    let target = createPath(createEnvironment, client)
                    _ = try await ArcaneAPIHelpers.send(client: client, path: target, method: .post, body: data)
                    await load()
                }
            }
        }
    }

    @ViewBuilder
    private func detailView(for item: EnvironmentItem<DynamicResource>) -> some View {
        if let detailDestination {
            detailDestination(item) { Task { await load() } }
        } else {
            DynamicResourceDetailView(
                title: item.title, resource: item.value, actions: actionsForRow(),
                basePath: manager.client.map { resourcePath(in: item.environmentID, client: $0) }
            )
        }
    }

    private func actionsForRow() -> [BackendListAction] {
        actions.filter { action in
            action.requiresSelection && !action.pathSuffix.isEmpty
        }
    }

    private func resourcePath(in environmentID: EnvironmentID, client: ArcaneClient) -> String {
        String(path(environmentID, client).split(separator: "?").first ?? "")
    }

    private func load() async {
        guard let client = manager.client else { return }
        let environments = await environmentsStore.listEnvironments(
            baseEnvironmentID, allEnvironments: showsAllEnvironments, manager: manager)
        await list.reload(environments, fetch: resourcesPage(client: client, environments: environments))
        rebuildDisplayedItems()
    }

    private func loadMore() async {
        guard let client = manager.client else { return }
        await list.loadMore(fetch: resourcesPage(client: client, environments: list.environments))
        rebuildDisplayedItems()
    }

    private func resourcesPage(
        client: ArcaneClient, environments: [ListEnvironment]
    ) -> EnvironmentPagedList<DynamicResource>.Fetch {
        let paths = Dictionary(uniqueKeysWithValues: environments.map { ($0.id, path($0.id, client)) })
        let query = debouncedSearchText.isEmpty ? [] : [URLQueryItem(name: "search", value: debouncedSearchText)]
        return { environmentID, start, limit in
            guard let path = paths[environmentID] else { throw ArcaneError.transport("Unknown environment") }
            let response: PaginatedResponse<DynamicResource> = try await client.rest.paginated(
                path, start: start, limit: limit, query: query)
            return ResourcePage(items: response.data, pagination: response.pagination)
        }
    }

    private func run(_ pending: PendingAction) async {
        guard let client = manager.client else { return }
        selectedAction = nil
        do {
            let target = actionPath(pending, client: client)
            _ = try await ArcaneAPIHelpers.send(client: client, path: target, method: pending.action.method)
            actionMessage = "\(pending.action.title) completed"
            await load()
        } catch {
            showToast(.error(friendlyErrorMessage(error)))
        }
    }

    /// Row actions target the row's environment; page-wide actions target the
    /// list's own environment.
    private func actionPath(_ pending: PendingAction, client: ArcaneClient) -> String {
        let base = resourcePath(in: pending.item?.environmentID ?? baseEnvironmentID, client: client)
        guard let item = pending.item else {
            return pending.action.pathSuffix.hasPrefix("/")
                ? base + pending.action.pathSuffix : pending.action.pathSuffix
        }
        let id = ArcaneAPIHelpers.escapedPathComponent(item.value.id)
        let suffix = pending.action.pathSuffix.replacingOccurrences(of: "{id}", with: id)
        if suffix.hasPrefix("/") {
            return base + suffix
        }
        return suffix
    }
}

private struct PendingAction: Identifiable {
    let id = UUID()
    let action: BackendListAction
    let item: EnvironmentItem<DynamicResource>?
}

struct DynamicResourceRow: View {
    let item: DynamicResource
    let systemImage: String

    var environmentName: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.body)
                Text(item.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                EnvironmentLabel(name: environmentName)
            }
            Spacer()
            if let status = item.statusText {
                Text(status)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct DynamicResourceDetailView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    let title: String
    let resource: DynamicResource
    let actions: [BackendListAction]
    /// The list endpoint (without query) that `/`-prefixed action suffixes extend.
    var basePath: String? = nil

    @State private var actionMessage: String?
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let actionMessage {
                Section {
                    Label(actionMessage, systemImage: "checkmark.circle").foregroundStyle(.green)
                }
            }
            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            }
            Section("Details") {
                ForEach(resource.sortedDetails, id: \.0) { key, value in
                    DynamicValueRow(key: key, value: value)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(title)
        .toolbar {
            if !actions.isEmpty {
                AppToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        ForEach(actions) { action in
                            Button(role: action.destructive ? .destructive : nil) {
                                Task { await run(action) }
                            } label: {
                                backendActionLabel(action)
                            }
                            .tint(action.destructive ? Color.red : nil)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Actions")
                }
            }
        }
    }

    private func run(_ action: BackendListAction) async {
        guard let client = manager.client else { return }
        let id = ArcaneAPIHelpers.escapedPathComponent(resource.id)
        let suffix = action.pathSuffix.replacingOccurrences(of: "{id}", with: id)
        let target = suffix.hasPrefix("/") ? (basePath ?? "") + suffix : suffix
        do {
            _ = try await ArcaneAPIHelpers.send(client: client, path: target, method: action.method)
            actionMessage = "\(action.title) completed"
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }
}

@ViewBuilder
private func backendActionLabel(_ action: BackendListAction) -> some View {
    if action.destructive {
        DestructiveLabel(text: action.title, systemImage: action.systemImage)
    } else {
        Label(action.title, systemImage: action.systemImage)
    }
}

struct DynamicValueRow: View {
    let key: String
    let value: AnyJSONValue

    var body: some View {
        switch value {
        case .object(let object):
            DisclosureGroup(prettyKey(key)) {
                ForEach(object.sorted(by: { $0.key.localizedStandardCompare($1.key) == .orderedAscending }), id: \.0) {
                    childKey, childValue in
                    DynamicValueRow(key: childKey, value: childValue)
                }
            }
        case .array(let array):
            DisclosureGroup("\(prettyKey(key)) (\(array.count))") {
                ForEach(Array(array.enumerated()), id: \.offset) { index, childValue in
                    DynamicValueRow(key: "\(index + 1)", value: childValue)
                }
            }
        default:
            LabeledContent(prettyKey(key), value: value.displayString)
        }
    }

    private func prettyKey(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

struct DynamicCreateFormView: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss

    let title: String
    let fields: [BackendFormField]
    let onSubmit: (Data) async throws -> Void

    @State private var values: [String: String] = [:]
    @State private var toggles: [String: Bool] = [:]
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var canSave: Bool {
        fields.allSatisfy { field in
            !field.required || field.type == .toggle
                || !(values[field.id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(fields) { field in
                        fieldView(field)
                    }
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                AppToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving..." : "Save") {
                        Task { await save() }
                    }
                    .disabled(isSaving || !canSave)
                }
            }
        }
    }

    @ViewBuilder
    private func fieldView(_ field: BackendFormField) -> some View {
        switch field.type {
        case .toggle:
            Toggle(
                field.label,
                isOn: Binding(
                    get: { toggles[field.id, default: false] },
                    set: { toggles[field.id] = $0 }
                ))
        case .secure:
            FormSecureField(
                title: field.label,
                placeholder: field.placeholder.isEmpty ? "Required" : field.placeholder,
                text: binding(field.id)
            )
        case .multiline:
            FormTextField(
                title: field.label,
                placeholder: field.placeholder.isEmpty ? "Value" : field.placeholder,
                text: binding(field.id),
                autocapitalization: .never,
                autocorrectionDisabled: true,
                axis: .vertical,
                lineLimit: 5...12
            )
        case .number:
            FormTextField(
                title: field.label,
                placeholder: field.placeholder.isEmpty ? "0" : field.placeholder,
                text: binding(field.id),
                keyboardType: .numbersAndPunctuation,
                autocapitalization: .never,
                autocorrectionDisabled: true
            )
        case .text:
            FormTextField(
                title: field.label,
                placeholder: field.placeholder.isEmpty ? "Value" : field.placeholder,
                text: binding(field.id),
                autocapitalization: .never,
                autocorrectionDisabled: true
            )
        }
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(
            get: { values[key, default: ""] },
            set: { values[key] = $0 }
        )
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let data = try ArcaneAPIHelpers.formBody(values: values, toggles: toggles, fields: fields)
            try await onSubmit(data)
            dismiss()
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }
}
