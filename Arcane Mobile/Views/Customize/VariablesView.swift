import SwiftUI
import Observation
import Arcane

struct VariablesView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager

    @State private var store = VariablesStore()
    @State private var editorRoute: VariableEditorRoute?
    @State private var pendingDelete: GlobalVariable?
    @State private var searchText = ""
    @State private var showsSyncStatus = false

    private var canRead: Bool {
        manager.permissions.has(Permission.Variables.read, in: nil)
    }

    private var canCreate: Bool {
        manager.permissions.has(Permission.Variables.create, in: nil)
    }

    private var canUpdate: Bool {
        manager.permissions.has(Permission.Variables.update, in: nil)
    }

    private var canDelete: Bool {
        manager.permissions.has(Permission.Variables.delete, in: nil)
    }

    private var canSync: Bool {
        manager.permissions.has(Permission.Variables.sync, in: nil)
    }

    private var filteredVariables: [GlobalVariable] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.variables }
        return store.variables.filter { variable in
            variable.key.localizedCaseInsensitiveContains(query)
                || (!variable.isSecret && variable.value.localizedCaseInsensitiveContains(query))
                || store.scopeLabel(for: variable).localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        Group {
            if !canRead {
                ContentUnavailableView {
                    Label("Variables Access Required", systemImage: "lock.fill")
                } description: {
                    Text("Your role cannot view global variables.")
                }
            } else if store.isLoading && store.variables.isEmpty {
                ProgressView("Loading variables…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.isUnsupported {
                ContentUnavailableView {
                    Label("Variables Unavailable", systemImage: "curlybraces")
                } description: {
                    Text("Update Arcane to manage scoped variables from the mobile app.")
                }
            } else if let errorMessage = store.errorMessage, store.variables.isEmpty {
                ContentUnavailableView {
                    Label("Couldn't Load Variables", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try Again") { Task { await load() } }
                }
            } else if store.variables.isEmpty {
                ContentUnavailableView {
                    Label("No Variables", systemImage: "curlybraces")
                } description: {
                    Text("Create a variable and choose which environments receive it.")
                } actions: {
                    if canCreate {
                        Button("Create Variable") { editorRoute = .create }
                    }
                }
            } else {
                variableList
            }
        }
        .navigationTitle("Variables")
        .searchable(text: $searchText, prompt: "Search variables")
        .toolbar {
            if canRead, !store.isUnsupported {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    if canSync {
                        Button {
                            Task { await syncVariables() }
                        } label: {
                            if store.isSyncing {
                                ProgressView()
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                        }
                        .disabled(store.isSyncing)
                        .accessibilityLabel("Sync variables")
                    }

                    if canCreate {
                        Button { editorRoute = .create } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Create variable")
                    }
                }
            }
        }
        .task(id: manager.serverURL) {
            guard canRead else { return }
            store.reset()
            await load()
        }
        .task(id: "\(manager.serverURL)#\(manager.clientGeneration)#\(store.pollingRevision)") {
            guard canRead, store.pollingRevision > 0, let client = manager.client else { return }
            await store.pollPendingSync(client: client)
        }
        .refreshable { await load() }
        .sheet(item: $editorRoute) { route in
            VariableEditorView(
                variable: route.variable,
                environments: store.environments
            ) { request in
                switch request {
                case .create where !canCreate, .update where !canUpdate:
                    throw ArcaneError.forbidden
                default:
                    break
                }
                guard let client = manager.client else {
                    throw ArcaneError.transport("No Arcane client is available")
                }
                try await store.save(request, client: client)
            }
        }
        .sheet(item: $pendingDelete) { variable in
            DeleteVariableView(variable: variable) {
                guard canDelete else { throw ArcaneError.forbidden }
                guard let client = manager.client else {
                    throw ArcaneError.transport("No Arcane client is available")
                }
                try await store.delete(variable, client: client)
            }
        }
    }

    private var variableList: some View {
        List {
            if !store.syncStatuses.isEmpty {
                Section {
                    DisclosureGroup(isExpanded: $showsSyncStatus) {
                        ForEach(store.syncStatuses) { status in
                            VariableSyncStatusRow(status: status)
                        }
                    } label: {
                        Label(store.syncSummary, systemImage: store.syncSummaryIcon)
                            .foregroundStyle(store.syncSummaryColor)
                    }
                }
            }

            Section("Variables") {
                if filteredVariables.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    ForEach(filteredVariables) { variable in
                        if canUpdate {
                            Button {
                                editorRoute = .edit(variable)
                            } label: {
                                VariableRow(
                                    variable: variable,
                                    scopeLabel: store.scopeLabel(for: variable)
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Opens variable editor")
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if canDelete {
                                    Button(role: .destructive) {
                                        pendingDelete = variable
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        } else {
                            VariableRow(
                                variable: variable,
                                scopeLabel: store.scopeLabel(for: variable)
                            )
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if canDelete {
                                    Button(role: .destructive) {
                                        pendingDelete = variable
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func load() async {
        guard canRead, let client = manager.client else { return }
        await store.load(client: client)
    }

    private func syncVariables() async {
        guard canSync, let client = manager.client else { return }
        do {
            try await store.sync(client: client)
            showToast(.success("Variables synced"))
        } catch {
            showToast(.error(friendlyErrorMessage(error)))
        }
    }

}

private struct VariableRow: View {
    let variable: GlobalVariable
    let scopeLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(variable.key)
                    .font(.headline.monospaced())
                    .foregroundStyle(.primary)
                if variable.isSecret {
                    Label("Secret", systemImage: "lock.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                        .labelStyle(.titleAndIcon)
                }
                Spacer()
            }

            Text(variable.isSecret ? "••••••••" : variable.value)
                .font(.subheadline.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Label(scopeLabel, systemImage: variable.allEnvironments ? "globe" : "server.rack")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
        }
        .padding(.vertical, 3)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

private struct VariableSyncStatusRow: View {
    let status: EnvironmentSyncStatus

    private var color: Color {
        switch status.status {
        case .synced: return .green
        case .pending: return .orange
        case .error: return .red
        case .unknown: return .secondary
        }
    }

    private var icon: String {
        switch status.status {
        case .synced: return "checkmark.circle.fill"
        case .pending: return "clock.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.environmentName?.nilIfEmpty ?? status.environmentID)
                    .font(.subheadline.weight(.medium))
                if let error = status.error?.nilIfEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if let lastSyncedAt = status.lastSyncedAt {
                    Text("Synced \(lastSyncedAt, style: .relative) ago")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(status.status.displayName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct VariableEditorRoute: Identifiable {
    let id: String
    let variable: GlobalVariable?

    static var create: VariableEditorRoute {
        VariableEditorRoute(id: "create-\(UUID().uuidString)", variable: nil)
    }

    static func edit(_ variable: GlobalVariable) -> VariableEditorRoute {
        VariableEditorRoute(id: variable.id, variable: variable)
    }
}

private struct DeleteVariableView: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss

    let variable: GlobalVariable
    let onDelete: () async throws -> Void

    @State private var isDeleting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Delete “\(variable.key)” and remove it from its environments?", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } footer: {
                    Text("This action cannot be undone.")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Delete Variable")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isDeleting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Delete", role: .destructive) {
                        Task { await delete() }
                    }
                    .disabled(isDeleting)
                }
            }
            .interactiveDismissDisabled(isDeleting)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private func delete() async {
        isDeleting = true
        errorMessage = nil
        defer { isDeleting = false }

        do {
            try await onDelete()
            showToast(.success("Variable deleted"))
            dismiss()
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }
}

private enum VariableSaveRequest {
    case create(CreateGlobalVariableRequest)
    case update(id: String, request: UpdateGlobalVariableRequest)
}

private struct VariableEnvironmentOption: Identifiable, Hashable {
    let id: String
    let name: String
}

private struct VariableEditorView: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss

    let variable: GlobalVariable?
    let environments: [Arcane.Environment]
    let onSave: (VariableSaveRequest) async throws -> Void

    @State private var key: String
    @State private var value: String
    @State private var isSecret: Bool
    @State private var allEnvironments: Bool
    @State private var selectedEnvironmentIDs: Set<String>
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(
        variable: GlobalVariable?,
        environments: [Arcane.Environment],
        onSave: @escaping (VariableSaveRequest) async throws -> Void
    ) {
        self.variable = variable
        self.environments = environments
        self.onSave = onSave
        _key = State(initialValue: variable?.key ?? "")
        _value = State(initialValue: variable?.isSecret == true ? "" : variable?.value ?? "")
        _isSecret = State(initialValue: variable?.isSecret ?? false)
        _allEnvironments = State(initialValue: variable?.allEnvironments ?? true)
        _selectedEnvironmentIDs = State(initialValue: Set(variable?.environmentIDs ?? []))
    }

    private var isEditing: Bool { variable != nil }

    private var environmentOptions: [VariableEnvironmentOption] {
        var options = environments.map {
            VariableEnvironmentOption(id: $0.id, name: $0.name?.nilIfEmpty ?? $0.id)
        }
        let known = Set(options.map(\.id))
        options.append(contentsOf: selectedEnvironmentIDs.subtracting(known).map {
            VariableEnvironmentOption(id: $0, name: $0)
        })
        return options.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var requiresReplacementValue: Bool {
        variable?.isSecret == true && !isSecret
    }

    private var canSave: Bool {
        let hasKey = !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasScope = allEnvironments || !selectedEnvironmentIDs.isEmpty
        let hasValue = !value.isEmpty
        let valueIsValid = isEditing ? (!requiresReplacementValue || hasValue) : hasValue
        return hasKey && hasScope && valueIsValid && !isSaving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    FormTextField(
                        title: "Key",
                        placeholder: "DATABASE_URL",
                        text: $key,
                        autocapitalization: .characters,
                        autocorrectionDisabled: true
                    )

                    Toggle("Secret", isOn: $isSecret)

                    if isSecret {
                        SecureField(isEditing ? "Leave blank to keep the current secret" : "Value", text: $value)
                            .textContentType(.password)
                    } else {
                        TextField("Value", text: $value, axis: .vertical)
                            .lineLimit(1...5)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text("Variable")
                } footer: {
                    if variable?.isSecret == true && isSecret {
                        Text("The current secret cannot be revealed. Leave the value blank to keep it unchanged.")
                    } else if requiresReplacementValue {
                        Text("Enter a replacement value before converting this secret to plain text.")
                    } else {
                        Text("Secret values are write-only and are never displayed or copied by the app.")
                    }
                }

                Section {
                    Toggle("All Environments", isOn: $allEnvironments)

                    if !allEnvironments {
                        if environmentOptions.isEmpty {
                            ContentUnavailableView(
                                "No Environments Available",
                                systemImage: "server.rack",
                                description: Text("Load environments or choose All Environments.")
                            )
                        } else {
                            ForEach(environmentOptions) { environment in
                                Toggle(
                                    environment.name,
                                    isOn: Binding(
                                        get: { selectedEnvironmentIDs.contains(environment.id) },
                                        set: { isSelected in
                                            if isSelected {
                                                selectedEnvironmentIDs.insert(environment.id)
                                            } else {
                                                selectedEnvironmentIDs.remove(environment.id)
                                            }
                                        }
                                    )
                                )
                            }
                        }
                    }
                } header: {
                    Text("Scope")
                } footer: {
                    Text("Scoped variables are materialized only into the selected environments.")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Variable" : "New Variable")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving { ProgressView() } else { Text("Save") }
                    }
                    .disabled(!canSave)
                }
            }
            .interactiveDismissDisabled(isSaving)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func save() async {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let scopedIDs = allEnvironments ? [] : selectedEnvironmentIDs.sorted()
        let request: VariableSaveRequest
        if let variable {
            request = .update(
                id: variable.id,
                request: UpdateGlobalVariableRequest(
                    key: trimmedKey,
                    value: value.isEmpty && variable.isSecret && isSecret ? nil : value,
                    isSecret: isSecret,
                    allEnvironments: allEnvironments,
                    environmentIDs: scopedIDs
                )
            )
        } else {
            request = .create(
                CreateGlobalVariableRequest(
                    key: trimmedKey,
                    value: value,
                    isSecret: isSecret,
                    allEnvironments: allEnvironments,
                    environmentIDs: scopedIDs
                )
            )
        }

        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await onSave(request)
            showToast(.success(isEditing ? "Variable updated" : "Variable created"))
            dismiss()
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }
}

@MainActor
@Observable
private final class VariablesStore {
    private(set) var variables: [GlobalVariable] = []
    private(set) var environments: [Arcane.Environment] = []
    private(set) var syncStatuses: [EnvironmentSyncStatus] = []
    private(set) var isLoading = false
    private(set) var isSyncing = false
    private(set) var isUnsupported = false
    private(set) var errorMessage: String?
    private(set) var pollingRevision = 0

    var syncSummary: String {
        let failures = syncStatuses.filter { $0.status == .error }.count
        let pending = syncStatuses.filter { $0.status == .pending }.count
        let unknown = syncStatuses.filter { $0.status.isUnknown }.count
        if failures > 0 { return "\(failures) environment\(failures == 1 ? "" : "s") failed to sync" }
        if pending > 0 { return "\(pending) environment\(pending == 1 ? "" : "s") pending" }
        if unknown > 0 { return "\(unknown) environment\(unknown == 1 ? "" : "s") has unknown status" }
        return "All environments synced"
    }

    var syncSummaryIcon: String {
        if syncStatuses.contains(where: { $0.status == .error }) {
            return "exclamationmark.triangle.fill"
        }
        if syncStatuses.contains(where: { $0.status == .pending }) {
            return "clock.fill"
        }
        if syncStatuses.contains(where: { $0.status.isUnknown }) {
            return "questionmark.circle.fill"
        }
        return "checkmark.circle.fill"
    }

    var syncSummaryColor: Color {
        if syncStatuses.contains(where: { $0.status == .error }) { return .red }
        if syncStatuses.contains(where: { $0.status == .pending }) { return .orange }
        if syncStatuses.contains(where: { $0.status.isUnknown }) { return .secondary }
        return .green
    }

    func reset() {
        variables = []
        environments = []
        syncStatuses = []
        isLoading = false
        isSyncing = false
        isUnsupported = false
        errorMessage = nil
        pollingRevision = 0
    }

    func load(client: ArcaneClient) async {
        if variables.isEmpty { isLoading = true }
        defer { isLoading = false }
        errorMessage = nil

        do {
            async let statusTask = try? client.variables.syncStatus()
            async let environmentTask = try? client.environments.list(
                query: SearchPaginationSort(start: 0, limit: 500, sortBy: "name", sortOrder: .ascending)
            )
            let loadedVariables = try await client.variables.list()
            variables = loadedVariables.sorted {
                $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending
            }
            let loadedStatuses = await statusTask
            let loadedEnvironments = await environmentTask
            syncStatuses = loadedStatuses ?? []
            environments = loadedEnvironments?.data ?? []
            isUnsupported = false
            requestPollingIfNeeded()
        } catch ArcaneError.notFound {
            isUnsupported = true
            variables = []
            syncStatuses = []
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }

    func save(_ request: VariableSaveRequest, client: ArcaneClient) async throws {
        let options = try ActivityBatchID.requestOptions()
        let response: GlobalVariableMutationResponse
        switch request {
        case .create(let body):
            response = try await client.variables.create(body, options: options)
        case .update(let id, let body):
            response = try await client.variables.update(id: id, request: body, options: options)
        }

        if let variable = response.variable {
            variables.removeAll { $0.id == variable.id }
            variables.append(variable)
            variables.sort { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
        }
        mergeSyncStatuses(response.syncResults)
        requestPolling()
    }

    func delete(_ variable: GlobalVariable, client: ArcaneClient) async throws {
        let options = try ActivityBatchID.requestOptions()
        let response = try await client.variables.delete(id: variable.id, options: options)
        variables.removeAll { $0.id == variable.id }
        mergeSyncStatuses(response.syncResults)
        requestPolling()
    }

    func sync(client: ArcaneClient) async throws {
        isSyncing = true
        defer { isSyncing = false }
        let options = try ActivityBatchID.requestOptions()
        syncStatuses = try await client.variables.sync(options: options)
        requestPolling()
    }

    func pollPendingSync(client: ArcaneClient) async {
        for attempt in 0...30 {
            do {
                if attempt > 0 {
                    try await Task.sleep(for: .seconds(2))
                }
                try Task.checkCancellation()
                syncStatuses = try await client.variables.syncStatus()
            } catch is CancellationError {
                return
            } catch {
                continue
            }

            if !syncStatuses.contains(where: { $0.status == .pending }) {
                return
            }
        }
    }

    func scopeLabel(for variable: GlobalVariable) -> String {
        if variable.allEnvironments {
            return "All environments"
        }
        guard !variable.environmentIDs.isEmpty else { return "No environments" }
        let namesByID = Dictionary(uniqueKeysWithValues: environments.map {
            ($0.id, $0.name?.nilIfEmpty ?? $0.id)
        })
        return variable.environmentIDs.map { namesByID[$0] ?? $0 }.joined(separator: ", ")
    }

    private func mergeSyncStatuses(_ statuses: [EnvironmentSyncStatus]) {
        guard !statuses.isEmpty else { return }
        var byID = Dictionary(uniqueKeysWithValues: syncStatuses.map { ($0.environmentID, $0) })
        for status in statuses { byID[status.environmentID] = status }
        syncStatuses = byID.values.sorted {
            ($0.environmentName ?? $0.environmentID)
                .localizedCaseInsensitiveCompare($1.environmentName ?? $1.environmentID) == .orderedAscending
        }
    }

    private func requestPollingIfNeeded() {
        if syncStatuses.contains(where: { $0.status == .pending }) {
            requestPolling()
        }
    }

    private func requestPolling() {
        pollingRevision &+= 1
    }
}

private extension VariableSyncState {
    var displayName: String {
        let value = rawValue.replacingOccurrences(of: "_", with: " ").capitalized
        return value.isEmpty ? "Unknown" : value
    }

    var isUnknown: Bool {
        if case .unknown = self { return true }
        return false
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
