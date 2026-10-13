import Arcane
import SwiftUI

/// Swarm configs and secrets share one shape: an immutable name + data blob.
/// Docker never returns secret data, so only configs show their contents.
struct SwarmKeyValueListView: View {
    enum Kind {
        case config, secret

        var title: String { self == .config ? "Configs" : "Secrets" }
        var singular: String { self == .config ? "Config" : "Secret" }
        var systemImage: String { self == .config ? "doc.text" : "key.fill" }
        var permission: String { self == .config ? Permission.Swarm.configs : Permission.Swarm.secrets }
    }

    /// Common fields of `SwarmConfigSummary` / `SwarmSecretSummary`.
    struct Item: Identifiable, Hashable {
        let id: String
        let spec: JSONValue
        let createdAt: Date
        let updatedAt: Date

        var name: String { spec["Name"]?.swarmString ?? String(id.prefix(12)) }

        /// Decoded `Data` for configs; nil when absent or not UTF-8.
        var decodedData: String? {
            guard let base64 = spec["Data"]?.swarmString, let data = Data(base64Encoded: base64) else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutationStore
    let kind: Kind
    let environmentID: EnvironmentID

    @State private var items: [Item] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var showCreate = false
    @State private var pendingDelete: Item?

    private var canManage: Bool { manager.permissions.has(kind.permission, in: environmentID) }
    private var swarmVersion: Int { mutationStore.version(kind: .swarm, envID: environmentID) }

    private var displayedItems: [Item] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return
            items
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        SwarmListState(
            isLoading: isLoading,
            isEmpty: items.isEmpty,
            errorMessage: errorMessage,
            emptyTitle: "No \(kind.title)",
            emptySystemImage: kind.systemImage,
            retry: { Task { await load() } }
        ) {
            List {
                Section {
                    ForEach(displayedItems) { item in
                        NavigationLink {
                            SwarmKeyValueDetailView(kind: kind, item: item, environmentID: environmentID)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(verbatim: item.name)
                                Text("Updated \(SwarmPresentation.date(item.updatedAt))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if canManage {
                                Button {
                                    pendingDelete = item
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .tint(.red)
                            }
                        }
                    }
                } header: {
                    Text(
                        verbatim:
                            "\(items.count) \(items.count == 1 ? kind.singular.lowercased() : kind.title.lowercased())")
                }
            }
            .listStyle(.insetGrouped)
            .softTopScrollEdgeEffectCompat()
        }
        .navigationTitle(kind.title)
        .searchable(
            text: $searchText, placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search \(kind.title.lowercased())"
        )
        .toolbar {
            if canManage {
                AppToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showCreate = true
                    } label: {
                        Image(systemName: "plus")
                            .appAccentToolbarSymbol()
                    }
                    .accessibilityLabel("Create \(kind.singular)")
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .onChange(of: swarmVersion) { _, _ in
            Task { await load() }
        }
        .sheet(isPresented: $showCreate) {
            SwarmKeyValueCreateView(kind: kind, environmentID: environmentID)
        }
        .deleteConfirmation(item: $pendingDelete) { item in
            DeleteConfirmationConfig(
                title: "Delete \(kind.singular)",
                message: "Delete “\(item.name)”? Services that use it must be updated first.",
                icon: "trash",
                actions: [
                    DeleteConfirmationAction(title: "Delete") {
                        Task { await delete(item) }
                    }
                ]
            )
        }
    }

    private func load() async {
        guard let client = manager.client, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            switch kind {
            case .config:
                items = try await client.swarm.listConfigs(envID: environmentID).map {
                    Item(id: $0.id, spec: $0.spec, createdAt: $0.createdAt, updatedAt: $0.updatedAt)
                }
            case .secret:
                items = try await client.swarm.listSecrets(envID: environmentID).map {
                    Item(id: $0.id, spec: $0.spec, createdAt: $0.createdAt, updatedAt: $0.updatedAt)
                }
            }
            errorMessage = nil
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func delete(_ item: Item) async {
        guard let client = manager.client else { return }
        do {
            try await SwarmKeyValueListView.delete(item, kind: kind, client: client, environmentID: environmentID)
            items.removeAll { $0.id == item.id }
            await manager.swarmChanged(environmentID, mutationStore: mutationStore)
            showToast(.success("\(kind.singular) deleted"))
        } catch {
            showToast(.error(friendlyErrorMessage(error)))
        }
    }

    static func delete(_ item: Item, kind: Kind, client: ArcaneClient, environmentID: EnvironmentID) async throws {
        switch kind {
        case .config: try await client.swarm.deleteConfig(item.id, envID: environmentID)
        case .secret: try await client.swarm.deleteSecret(item.id, envID: environmentID)
        }
    }
}

struct SwarmKeyValueDetailView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutationStore
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let kind: SwarmKeyValueListView.Kind
    let item: SwarmKeyValueListView.Item
    let environmentID: EnvironmentID

    @State private var isDeleting = false

    private var canManage: Bool { manager.permissions.has(kind.permission, in: environmentID) }

    var body: some View {
        List {
            Section("Details") {
                LabeledContent("Name", value: item.name)
                LabeledContent("ID") {
                    Button {
                        UIPasteboard.general.string = item.id
                        showToast(.copied())
                    } label: {
                        HStack(spacing: 6) {
                            MonospacedValue(value: String(item.id.prefix(12)))
                            Image(systemName: "doc.on.doc")
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Copy ID")
                }
                LabeledContent("Created", value: SwarmPresentation.date(item.createdAt))
                LabeledContent("Updated", value: SwarmPresentation.date(item.updatedAt))
            }
            if kind == .config {
                Section("Data") {
                    if let data = item.decodedData {
                        Text(verbatim: data)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    } else {
                        Text("Binary or empty data.")
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Section {
                    Label("Secret values can't be read back from Docker.", systemImage: "lock.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .softTopScrollEdgeEffectCompat()
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .resourceActionsToolbar(
            overflow: canManage
                ? [
                    ActionButtonItem(
                        id: "delete", title: "Delete", systemImage: "trash", tint: .red, role: .destructive,
                        confirmationMessage:
                            "Services that use this \(kind.singular.lowercased()) must be updated first."
                    ) {
                        Task { await delete() }
                    }
                ] : [],
            runningItemID: isDeleting ? "delete" : nil,
            isDisabled: isDeleting,
            resourceName: item.name,
            active: canManage
        )
    }

    private func delete() async {
        guard let client = manager.client else { return }
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await SwarmKeyValueListView.delete(item, kind: kind, client: client, environmentID: environmentID)
            await manager.swarmChanged(environmentID, mutationStore: mutationStore)
            showToast(.success("\(kind.singular) deleted"))
            dismiss()
        } catch {
            showToast(.error(friendlyErrorMessage(error)))
        }
    }
}

private struct SwarmKeyValueCreateView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutationStore
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let kind: SwarmKeyValueListView.Kind
    let environmentID: EnvironmentID

    @State private var name = ""
    @State private var data = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    FormTextField(
                        title: "Name", placeholder: kind == .config ? "nginx.conf" : "db_password", text: $name,
                        autocapitalization: .never, autocorrectionDisabled: true)
                }
                Section {
                    if kind == .secret {
                        FormSecureField(title: "Value", placeholder: "Required", text: $data)
                    } else {
                        CodeEditorView(text: $data, language: .plaintext)
                            .frame(minHeight: 220)
                    }
                } header: {
                    Text(kind == .config ? "Data" : "Secret")
                } footer: {
                    Text("\(kind.title) can't be changed after they're created.")
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }
            }
            .navigationTitle("Create \(kind.singular)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                AppToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task { await create() }
                    }
                    .disabled(isSaving || trimmedName.isEmpty || data.isEmpty)
                }
            }
            .interactiveDismissDisabled(isSaving || !data.isEmpty)
        }
    }

    private func create() async {
        guard let client = manager.client else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        let spec = JSONValue.object([
            "Name": .string(trimmedName),
            "Data": .string(Data(data.utf8).base64EncodedString()),
        ])
        do {
            switch kind {
            case .config:
                _ = try await client.swarm.createConfig(SwarmConfigCreateRequest(spec: spec), envID: environmentID)
            case .secret:
                _ = try await client.swarm.createSecret(SwarmSecretCreateRequest(spec: spec), envID: environmentID)
            }
            await manager.swarmChanged(environmentID, mutationStore: mutationStore)
            showToast(.success("\(kind.singular) created"))
            dismiss()
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }
}
