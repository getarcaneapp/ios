import SwiftUI
import Arcane

struct APIKeysView: View {
    private static let pageSize = 50

    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @State private var apiKeys: [APIKey] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showCreateSheet = false
    @State private var createdKey: String?
    @State private var actionErrorMessage: String?
    @State private var pendingDeleteKey: APIKey?
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var pagination = ProgressivePaginationState()
    @State private var isLoadingMore = false
    @State private var loadMoreError: String?

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
                ContentUnavailableView {
                    Label("No API Keys", systemImage: "key.slash")
                } description: {
                    Text("Create a key to access the Arcane API from scripts and integrations.")
                } actions: {
                    Button("Create API Key") { showCreateSheet = true }
                }
            } else {
                List {
                    Section {
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

                        if pagination.hasMore {
                            if loadMoreError != nil {
                                Button("Retry loading more") {
                                    Task { await loadMore() }
                                }
                                .frame(maxWidth: .infinity)
                            } else {
                                SkeletonListRow()
                                    .skeletonShimmer()
                                    .onAppear {
                                        Task { await loadMore() }
                                    }
                            }
                        }
                    } header: {
                        ResourceCountSectionHeader(
                            "API Keys",
                            loadedCount: apiKeys.count,
                            totalCount: pagination.totalItems,
                            hasMore: pagination.hasMore
                        )
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("API Keys")
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search API keys"
        )
        .debounce(searchText, for: .milliseconds(200), into: $debouncedSearchText)
        .onChange(of: debouncedSearchText) {
            Task { await loadKeys(refresh: true) }
        }
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
                Button { showCreateSheet = true } label: { Image(systemName: "plus") }.accessibilityLabel("Create API Key")
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
        guard let client = manager.client else { return }
        let generation = pagination.reset()
        isLoadingMore = false
        if apiKeys.isEmpty { isLoading = true }
        errorMessage = nil
        loadMoreError = nil
        defer {
            if pagination.accepts(generation) {
                isLoading = false
            }
        }
        do {
            let response = try await client.apiKeys.listPaginated(
                search: debouncedSearchText.isEmpty ? nil : debouncedSearchText,
                start: 0,
                limit: Self.pageSize
            )
            applyPage(response, reset: true, requestedStart: 0, generation: generation)
        } catch {
            guard pagination.accepts(generation) else { return }
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func loadMore() async {
        guard pagination.hasMore, !isLoadingMore, let client = manager.client else { return }
        isLoadingMore = true
        loadMoreError = nil
        let generation = pagination.generation
        let start = pagination.nextStart
        defer {
            if pagination.accepts(generation) {
                isLoadingMore = false
            }
        }
        do {
            let response = try await client.apiKeys.listPaginated(
                search: debouncedSearchText.isEmpty ? nil : debouncedSearchText,
                start: start,
                limit: Self.pageSize
            )
            applyPage(response, reset: false, requestedStart: start, generation: generation)
        } catch {
            guard pagination.accepts(generation) else { return }
            loadMoreError = friendlyErrorMessage(error)
        }
    }

    private func applyPage(
        _ response: PaginatedResponse<APIKey>,
        reset: Bool,
        requestedStart: Int,
        generation: Int
    ) {
        guard pagination.receive(
            pagination: response.pagination,
            itemCount: response.data.count,
            requestedStart: requestedStart,
            requestedLimit: Self.pageSize,
            generation: generation
        ) else { return }
        apiKeys = PaginationLoader.merge(current: apiKeys, incoming: response.data, reset: reset)
        loadMoreError = nil
        errorMessage = nil
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
            await loadKeys(refresh: true)
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
