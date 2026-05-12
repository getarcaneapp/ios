import SwiftUI
import Arcane

struct DynamicResourceListView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager

    let title: String
    let systemImage: String
    let path: (ArcaneClientManager, ArcaneClient) -> String
    var emptyTitle: String? = nil
    var actions: [BackendListAction] = []
    var createTitle: String? = nil
    var createFields: [BackendFormField] = []
    var createPath: ((ArcaneClientManager, ArcaneClient) -> String)? = nil

    @State private var items: [DynamicResource] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var actionMessage: String?
    @State private var selectedAction: PendingAction?
    @State private var showCreateSheet = false

    private var filteredItems: [DynamicResource] {
        items
            .filter { item in
                searchText.isEmpty ||
                item.title.localizedCaseInsensitiveContains(searchText) ||
                item.subtitle.localizedCaseInsensitiveContains(searchText)
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        Group {
            if isLoading && items.isEmpty {
                ProgressView("Loading \(title.lowercased())...").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage, items.isEmpty {
                ContentUnavailableView("Error", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else if items.isEmpty {
                ContentUnavailableView(emptyTitle ?? "No \(title)", systemImage: systemImage)
            } else {
                List {
                    if let actionMessage {
                        Section {
                            Label(actionMessage, systemImage: "checkmark.circle")
                                .foregroundStyle(.green)
                        }
                    }
                    ForEach(filteredItems) { item in
                        NavigationLink {
                            DynamicResourceDetailView(title: item.title, resource: item, actions: actionsForRow(item))
                        } label: {
                            DynamicResourceRow(item: item, systemImage: systemImage)
                        }
                        .contextMenu {
                            ForEach(actionsForRow(item)) { action in
                                Button(role: action.destructive ? .destructive : nil) {
                                    selectedAction = PendingAction(action: action, item: item)
                                } label: {
                                    Label(action.title, systemImage: action.systemImage)
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle(title)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search \(title.lowercased())")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { Task { await load(refresh: true) } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh")
            }
            if createPath != nil, !createFields.isEmpty {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showCreateSheet = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(createTitle ?? "Create")
                }
            }
            let globalActions = actions.filter { !$0.requiresSelection }
            if !globalActions.isEmpty {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        ForEach(globalActions) { action in
                            Button(role: action.destructive ? .destructive : nil) {
                                selectedAction = PendingAction(action: action, item: nil)
                            } label: {
                                Label(action.title, systemImage: action.systemImage)
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("More options")
                }
            }
        }
        .task { await load() }
        .refreshable { await load(refresh: true) }
        .alert(selectedAction?.action.title ?? "Run Action", isPresented: Binding(
            get: { selectedAction != nil },
            set: { if !$0 { selectedAction = nil } }
        )) {
            if let selectedAction {
                Button(selectedAction.action.title, role: selectedAction.action.destructive ? .destructive : nil) {
                    Task { await run(selectedAction) }
                }
            }
            Button("Cancel", role: .cancel) { selectedAction = nil }
        } message: {
            if let selectedAction {
                Text(selectedAction.item.map { "\(selectedAction.action.title) \($0.title)?" } ?? "\(selectedAction.action.title)?")
            }
        }
        .sheet(isPresented: $showCreateSheet) {
            if let createPath {
                DynamicCreateFormView(
                    title: createTitle ?? "Create \(title)",
                    fields: createFields
                ) { data in
                    guard let client = manager.client else { return }
                    let target = createPath(manager, client)
                    _ = try await ArcaneAPIHelpers.send(client: client, path: target, method: .post, body: data)
                    await load(refresh: true)
                }
            }
        }
    }

    private func actionsForRow(_ item: DynamicResource) -> [BackendListAction] {
        actions.filter { action in
            action.requiresSelection && !action.pathSuffix.isEmpty
        }
    }

    private func load(refresh: Bool = false) async {
        guard let client = manager.client else { return }
        if items.isEmpty { isLoading = true }
        errorMessage = nil
        defer { isLoading = false }
        do {
            items = try await ArcaneAPIHelpers.loadList(client: client, path: path(manager, client))
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func run(_ pending: PendingAction) async {
        guard let client = manager.client else { return }
        selectedAction = nil
        do {
            let target = actionPath(pending, manager: manager, client: client)
            _ = try await ArcaneAPIHelpers.send(client: client, path: target, method: pending.action.method)
            actionMessage = "\(pending.action.title) completed"
            await load(refresh: true)
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func actionPath(_ pending: PendingAction, manager: ArcaneClientManager, client: ArcaneClient) -> String {
        let base = path(manager, client)
        guard let item = pending.item else {
            return pending.action.pathSuffix.hasPrefix("/") ? String(base.split(separator: "?").first ?? "") + pending.action.pathSuffix : pending.action.pathSuffix
        }
        let id = ArcaneAPIHelpers.escapedPathComponent(item.id)
        let suffix = pending.action.pathSuffix.replacingOccurrences(of: "{id}", with: id)
        if suffix.hasPrefix("/") {
            return String(base.split(separator: "?").first ?? "") + suffix
        }
        return suffix
    }
}

private struct PendingAction: Identifiable {
    let id = UUID()
    let action: BackendListAction
    let item: DynamicResource?
}

struct DynamicResourceRow: View {
    let item: DynamicResource
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(item.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if let status = item.statusText {
                Text(status)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

struct DynamicResourceDetailView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    let title: String
    let resource: DynamicResource
    let actions: [BackendListAction]

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
        .navigationTitle(title)
        .toolbar {
            if !actions.isEmpty {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        ForEach(actions) { action in
                            Button(role: action.destructive ? .destructive : nil) {
                                Task { await run(action) }
                            } label: {
                                Label(action.title, systemImage: action.systemImage)
                            }
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
        let target = action.pathSuffix.replacingOccurrences(of: "{id}", with: id)
        do {
            _ = try await ArcaneAPIHelpers.send(client: client, path: target, method: action.method)
            actionMessage = "\(action.title) completed"
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }
}

struct DynamicValueRow: View {
    let key: String
    let value: AnyJSONValue

    var body: some View {
        switch value {
        case .object(let object):
            DisclosureGroup(prettyKey(key)) {
                ForEach(object.sorted(by: { $0.key.localizedStandardCompare($1.key) == .orderedAscending }), id: \.0) { childKey, childValue in
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
            !field.required || field.type == .toggle || !(values[field.id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
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
            Toggle(field.label, isOn: Binding(
                get: { toggles[field.id, default: false] },
                set: { toggles[field.id] = $0 }
            ))
        case .secure:
            SecureField(field.placeholder.isEmpty ? field.label : field.placeholder, text: binding(field.id))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        case .multiline:
            TextField(field.placeholder.isEmpty ? field.label : field.placeholder, text: binding(field.id), axis: .vertical)
                .lineLimit(5...12)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        case .number:
            TextField(field.placeholder.isEmpty ? field.label : field.placeholder, text: binding(field.id))
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        case .text:
            TextField(field.placeholder.isEmpty ? field.label : field.placeholder, text: binding(field.id))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
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
