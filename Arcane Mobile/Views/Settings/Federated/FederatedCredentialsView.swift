import SwiftUI
import Arcane

struct FederatedCredentialsView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @State private var credentials: [FederatedCredential] = []
    @State private var total = 0
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var unsupported = false
    @State private var creating = false
    @State private var search = ""
    @State private var pendingDelete: FederatedCredential?
    private var canManage: Bool { manager.currentUser?.isGlobalAdmin == true }
    private var identity: String { "\(manager.clientGeneration)|\(manager.client?.configuration.baseURL.absoluteString ?? "")|\(manager.currentUser?.id ?? "")|\(search)" }

    var body: some View {
        List {
            if unsupported {
                ContentUnavailableView("Federated Credentials Unavailable", systemImage: "key.slash", description: Text("This server does not support federated credential management."))
            } else {
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                ForEach(credentials) { credential in
                    NavigationLink {
                        FederatedCredentialDetailView(credential: credential, onSaved: { await load(reset: true) })
                    } label: {
                        VStack(alignment: .leading) {
                            Text(credential.name)
                            Text(credential.issuerUrl).font(.caption).foregroundStyle(.secondary)
                            Text(credential.enabled ? "Enabled" : "Disabled").font(.caption)
                        }
                    }
                    .disabled(!manager.permissions.has("federated:read", in: nil))
                    .swipeActions(allowsFullSwipe: false) {
                        if canManage {
                            Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = credential }
                        }
                    }
                }
                if loading { ProgressView() }
                else if credentials.count < total { Button("Load more") { Task { await load(reset: false) } } }
                else if credentials.isEmpty && errorMessage == nil { Text("No federated credentials").foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Federated Credentials")
        .searchable(text: $search)
        .toolbar { if canManage && !unsupported { Button("Create", systemImage: "plus") { creating = true } } }
        .task(id: identity) { await load(reset: true) }
        .refreshable { await load(reset: true) }
        .sheet(isPresented: $creating) { FederatedCredentialFormView(credential: nil, onSaved: { await load(reset: true) }) }
        .deleteConfirmation(item: $pendingDelete, title: { _ in "Delete Credential" },
            message: { "Delete \($0.name) and its service user?" }, icon: "trash", confirmTitle: "Delete") { credential in
            Task {
                guard canManage, let client = manager.client else { return }
                do { try await client.federatedCredentials.delete(id: credential.id); await load(reset: true) }
                catch { showToast(.error(friendlyErrorMessage(error))) }
            }
        }
    }

    private func load(reset: Bool) async {
        guard manager.serverCapabilities?.supportsRoleManagement == true,
              manager.permissions.has("federated:list", in: nil), let client = manager.client else { return }
        let key = identity
        if reset { credentials = []; total = 0; unsupported = false }
        loading = true
        errorMessage = nil
        defer { if identity == key { loading = false } }
        do {
            let result = try await client.federatedCredentials.list(query: .init(search: search, start: reset ? 0 : credentials.count, limit: 30, sortBy: "name", sortOrder: .ascending))
            guard !Task.isCancelled, key == identity else { return }
            credentials += result.data.filter { row in !credentials.contains { $0.id == row.id } }
            total = Int(result.pagination.totalItems)
        } catch {
            guard !Task.isCancelled, key == identity else { return }
            unsupported = (error as? ArcaneError) == .notFound
            errorMessage = friendlyErrorMessage(error)
        }
    }
}

struct FederatedCredentialDetailView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @State var credential: FederatedCredential
    let onSaved: () async -> Void
    @State private var editing = false

    var body: some View {
        Form {
            Section("Trust rule") {
                LabeledContent("Issuer", value: credential.issuerUrl)
                LabeledContent("Audiences", value: credential.audiences.joined(separator: ", "))
                LabeledContent("Subject claim", value: credential.subjectClaim)
                LabeledContent("Match", value: credential.subjectMatch)
                LabeledContent("Match type", value: credential.matchType)
                LabeledContent("Status", value: credential.enabled ? "Enabled" : "Disabled")
            }
            Section("Access") {
                LabeledContent("Role", value: credential.roleName ?? credential.roleId)
                LabeledContent("Environment", value: credential.environmentName ?? credential.environmentId ?? "Global")
                LabeledContent("Service user", value: credential.serviceUsername ?? credential.identityUserId)
                LabeledContent("Token lifetime", value: "\(credential.tokenTtlSeconds) seconds")
                if let used = credential.lastUsedAt { LabeledContent("Last used", value: used.formatted()) }
                if let expires = credential.expiresAt { LabeledContent("Expires", value: expires.formatted()) }
            }
        }
        .navigationTitle(credential.name)
        .onChange(of: manager.clientGeneration) { dismiss() }
        .toolbar { if manager.currentUser?.isGlobalAdmin == true { Button("Edit") { editing = true } } }
        .sheet(isPresented: $editing) {
            FederatedCredentialFormView(credential: credential) {
                if let client = manager.client { do { credential = try await client.federatedCredentials.get(id: credential.id) } catch { showToast(.error(friendlyErrorMessage(error))) } }
                await onSaved()
            }
        }
    }
}
