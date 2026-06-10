import SwiftUI
import Arcane

struct APIKeysView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @State private var apiKeys: [APIKey] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showCreateSheet = false
    @State private var createdKey: String?
    @State private var actionErrorMessage: String?
    @State private var pendingDeleteKey: APIKey?

    var body: some View {
        Group {
            if isLoading && apiKeys.isEmpty {
                ProgressView("Loading API keys...").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage, apiKeys.isEmpty {
                ContentUnavailableView {
                    Label("Couldn't Load API Keys", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try Again") { Task { await loadKeys(refresh: true) } }
                }
            } else if apiKeys.isEmpty {
                ContentUnavailableView("No API Keys", systemImage: "key.slash", description: nil)
            } else {
                List {
                    ForEach(apiKeys) { key in
                        APIKeyRow(apiKey: key)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if key.isProtected != true {
                                    Button {
                                        pendingDeleteKey = key
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    .tint(.red)
                                }
                            }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("API Keys")
        .deleteConfirmation(
            item: $pendingDeleteKey,
            title: { _ in "Delete API Key" },
            message: { _ in "This permanently revokes the API key. Anything using it will stop working." },
            icon: "trash",
            confirmTitle: "Delete"
        ) { key in
            Task { await deleteKey(key) }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showCreateSheet = true } label: { Image(systemName: "plus") }
            }
        }
        .task { await loadKeys() }
        .refreshable { await loadKeys(refresh: true) }
        .sheet(isPresented: $showCreateSheet) {
            CreateAPIKeyView { keyString in
                createdKey = keyString
                Task {
                    if let cached = manager.cached {
                        await cached.invalidateGlobal(paths: ["api-keys", "api-keys/*"])
                    }
                    await loadKeys(refresh: true)
                }
            }
        }
        .sheet(item: Binding(get: { createdKey.map { CreatedKeyWrapper(key: $0) } }, set: { _ in createdKey = nil })) { wrapper in
            NewAPIKeyView(key: wrapper.key)
        }
        .alert(
            "Couldn't Delete API Key",
            isPresented: Binding(
                get: { actionErrorMessage != nil },
                set: { if !$0 { actionErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { actionErrorMessage = nil }
        } message: {
            Text(actionErrorMessage ?? "")
        }
    }

    private func loadKeys(refresh: Bool = false) async {
        guard let cached = manager.cached else { return }
        if apiKeys.isEmpty { isLoading = true }
        if refresh { errorMessage = nil }
        defer { isLoading = false }
        do {
            if let result: [APIKey] = try await cached.getListGlobal(
                "api-keys", elementType: APIKey.self, policy: .apiKeys,
                refresh: refresh,
                onFresh: { fresh in apiKeys = fresh }
            ) {
                apiKeys = result
            }
            errorMessage = nil
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func deleteKey(_ key: APIKey) async {
        guard let client = manager.client else { return }
        do {
            let _: DataResponse<String> = try await client.rest.delete("api-keys/\(key.id)")
            withAnimation {
                apiKeys.removeAll { $0.id == key.id }
            }
            if let cached = manager.cached {
                await cached.invalidateGlobal(paths: ["api-keys", "api-keys/*"])
            }
        } catch {
            actionErrorMessage = friendlyErrorMessage(error)
        }
    }
}

private struct CreatedKeyWrapper: Identifiable {
    let id = UUID()
    let key: String
}

struct APIKeyRow: View {
    let apiKey: APIKey
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(apiKey.name).font(.headline)
                Spacer()
                if apiKey.isProtected == true {
                    Image(systemName: "lock.fill").foregroundStyle(.secondary).font(.caption)
                }
            }
            if let desc = apiKey.description, !desc.isEmpty {
                Text(desc).font(.caption).foregroundStyle(.secondary)
            }
            if let expires = apiKey.expiresAt {
                Text("Expires: \(expires)").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

