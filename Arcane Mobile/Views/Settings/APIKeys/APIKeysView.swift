import SwiftUI
import Arcane

private enum APIKeySortField: String, CaseIterable, Identifiable {
    case name
    case expiresAt
    case lastUsedAt

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return "Name"
        case .expiresAt: return "Expiration"
        case .lastUsedAt: return "Last Used"
        }
    }
}

struct APIKeysView: View {
    private static let pageSize = 50

    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @State private var apiKeys: [APIKey] = []
    @State private var assignedUsers: [String: User] = [:]
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showCreateSheet = false
    @State private var revealedKey: APIKeySecretPresentation?
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var sortField = APIKeySortField.name
    @State private var sortOrder = Arcane.SortOrder.ascending
    @State private var pagination = ProgressivePaginationState()
    @State private var isLoadingMore = false
    @State private var loadMoreError: String?

    private var supportsRBAC: Bool {
        manager.serverCapabilities?.supportsRoleManagement == true
    }

    private var canCreate: Bool {
        if !supportsRBAC { return manager.currentUser?.isAdmin == true }
        return manager.permissions.has(Permission.ApiKeys.create, in: nil)
    }

    private var canListUsers: Bool {
        if !supportsRBAC { return manager.currentUser?.isAdmin == true }
        return manager.permissions.has(Permission.Users.list, in: nil)
    }

    var body: some View {
        Group {
            if isLoading && apiKeys.isEmpty {
                ProgressView("Loading API keys…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage, apiKeys.isEmpty {
                ContentUnavailableView {
                    Label("Couldn't Load API Keys", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try Again") { Task { await loadKeys(refresh: true) } }
                }
            } else if apiKeys.isEmpty && !debouncedSearchText.isEmpty {
                ContentUnavailableView {
                    Label("No Results", systemImage: "magnifyingglass")
                } description: {
                    Text("No API keys match “\(debouncedSearchText)”.")
                } actions: {
                    Button("Clear Search") { searchText = "" }
                }
            } else if apiKeys.isEmpty {
                ContentUnavailableView {
                    Label("No API Keys", systemImage: "key.slash")
                } description: {
                    Text("Create a key to access the Arcane API from scripts and integrations.")
                } actions: {
                    if canCreate {
                        Button("Create API Key") { showCreateSheet = true }
                    }
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ResourceCountSectionHeader(
                            "API Keys",
                            loadedCount: apiKeys.count,
                            totalCount: pagination.totalItems,
                            hasMore: pagination.hasMore
                        )

                        ForEach(apiKeys) { key in
                            keyLink(key)
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
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 16)
                }
                .softTopScrollEdgeEffectCompat()
                .background(Color(uiColor: .systemGroupedBackground))
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
        .onChange(of: sortField) {
            Task { await loadKeys(refresh: true) }
        }
        .onChange(of: sortOrder) {
            Task { await loadKeys(refresh: true) }
        }
        .toolbar { toolbarContent }
        .task { await loadKeys() }
        .refreshable { await loadKeys(refresh: true) }
        .sheet(isPresented: $showCreateSheet) {
            CreateAPIKeyView { created in
                revealedKey = .created(created.key)
                Task {
                    await invalidateAPIKeyCache()
                    await loadKeys(refresh: true)
                }
            }
        }
        .sheet(item: $revealedKey) { presentation in
            NewAPIKeyView(presentation: presentation)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Picker("Sort By", selection: $sortField) {
                    ForEach(APIKeySortField.allCases) { field in
                        Text(field.title).tag(field)
                    }
                }
                Picker("Order", selection: $sortOrder) {
                    Label("Ascending", systemImage: "arrow.up").tag(Arcane.SortOrder.ascending)
                    Label("Descending", systemImage: "arrow.down").tag(Arcane.SortOrder.descending)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("API key options")
        }

        if #available(iOS 26, *), canCreate {
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
        }

        if canCreate {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showCreateSheet = true } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Create API Key")
            }
        }
    }

    private func keyLink(_ key: APIKey) -> some View {
        let user = key.userId.flatMap { assignedUsers[$0] }
        return NavigationLink {
            APIKeyDetailView(apiKey: key, assignedUser: user) {
                await loadKeys(refresh: true)
            }
        } label: {
            APIKeyRow(apiKey: key, assignedUser: user)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(.rect)
        }
        .cardRowLinkStyle()
        .dashboardCardBackground(cornerRadius: Radius.standard)
        .contextMenu {
            Button {
                UIPasteboard.general.string = key.keyPrefix
                showToast(.copied("Key prefix copied"))
            } label: {
                Label("Copy Key Prefix", systemImage: "doc.on.doc")
            }
        } preview: {
            RowPreviewCard(
                icon: "key.fill",
                iconColor: .yellow,
                title: key.name,
                subtitle: key.description,
                badges: [
                    .init(
                        text: key.expiresAt.map { $0 <= Date() } == true ? "Expired" : "Active",
                        color: key.expiresAt.map { $0 <= Date() } == true ? .red : .green
                    )
                ],
                details: [
                    .init(icon: "number", label: "Key Prefix", value: "\(key.keyPrefix)…", monospaced: true),
                    .init(icon: "person.fill", label: "Assigned To", value: APIKeyOwnerText.title(user: user, userID: key.userId)),
                    .init(icon: "calendar", label: "Expires", value: APIKeyDateText.expiration(key.expiresAt))
                ]
            )
        }
    }

    private func loadKeys(refresh: Bool = false) async {
        guard let client = manager.client else { return }
        let generation = pagination.reset()
        let shouldLoadUsers = canListUsers
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
            async let pageTask = client.apiKeys.listPaginated(
                search: debouncedSearchText.isEmpty ? nil : debouncedSearchText,
                sort: sortField.rawValue,
                order: sortOrder,
                start: 0,
                limit: Self.pageSize
            )
            async let usersTask = fetchAssignedUsers(using: client, enabled: shouldLoadUsers)
            let response = try await pageTask
            let users = await usersTask
            guard applyPage(response, reset: true, requestedStart: 0, generation: generation) else { return }

            var usersByID = Dictionary(uniqueKeysWithValues: users.map { ($0.id, $0) })
            if let currentUser = manager.currentUser {
                usersByID[currentUser.id] = currentUser
            }
            assignedUsers = usersByID
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
                sort: sortField.rawValue,
                order: sortOrder,
                start: start,
                limit: Self.pageSize
            )
            _ = applyPage(response, reset: false, requestedStart: start, generation: generation)
        } catch {
            guard pagination.accepts(generation) else { return }
            loadMoreError = friendlyErrorMessage(error)
        }
    }

    @discardableResult
    private func applyPage(
        _ response: PaginatedResponse<APIKey>,
        reset: Bool,
        requestedStart: Int,
        generation: Int
    ) -> Bool {
        guard pagination.receive(
            pagination: response.pagination,
            itemCount: response.data.count,
            requestedStart: requestedStart,
            requestedLimit: Self.pageSize,
            generation: generation
        ) else { return false }

        apiKeys = PaginationLoader.merge(current: apiKeys, incoming: response.data, reset: reset)
        loadMoreError = nil
        errorMessage = nil
        return true
    }

    private func fetchAssignedUsers(using client: ArcaneClient, enabled: Bool) async -> [User] {
        guard enabled else { return [] }
        do {
            return try await PaginationLoader.collect { start, limit in
                let response = try await client.users.listPaginated(start: start, limit: limit)
                return ResourcePage(items: response.data, pagination: response.pagination)
            }
        } catch {
            // API-key access and user-list access are separate v2 permissions.
            // Keep the keys usable even when owner profiles cannot be fetched.
            return []
        }
    }

    private func invalidateAPIKeyCache() async {
        if let cached = manager.cached {
            await cached.invalidateGlobal(paths: ["api-keys", "api-keys/*"])
        }
    }
}

struct APIKeyRow: View {
    let apiKey: APIKey
    let assignedUser: User?

    private var isExpired: Bool {
        apiKey.expiresAt.map { $0 <= Date() } == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "key.fill")
                    .font(.title3)
                    .foregroundStyle(.yellow)
                    .frame(width: 38, height: 38)
                    .background(.regularMaterial, in: .circle)

                VStack(alignment: .leading, spacing: 3) {
                    Text(apiKey.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(verbatim: "\(apiKey.keyPrefix)…")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                APIKeyStatusBadge(isExpired: isExpired)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }

            if let description = apiKey.description, !description.isEmpty {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(alignment: .top, spacing: 12) {
                APIKeyCompactMetadata(
                    title: "Assigned To",
                    value: APIKeyOwnerText.title(user: assignedUser, userID: apiKey.userId),
                    systemImage: "person.fill"
                )
                APIKeyCompactMetadata(
                    title: "Last Used",
                    value: APIKeyDateText.lastUsed(apiKey.lastUsedAt),
                    systemImage: "clock.fill"
                )
            }

            HStack(spacing: 5) {
                Image(systemName: "calendar")
                    .accessibilityHidden(true)
                Text(APIKeyDateText.expiration(apiKey.expiresAt))
            }
            .font(.caption)
            .foregroundStyle(isExpired ? Color.red : Color(uiColor: .tertiaryLabel))
        }
        .accessibilityElement(children: .combine)
    }
}

private struct APIKeyCompactMetadata: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(value)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct APIKeyStatusBadge: View {
    let isExpired: Bool

    var body: some View {
        let tint: Color = isExpired ? .red : .green
        Label(
            isExpired ? "Expired" : "Active",
            systemImage: isExpired ? "xmark.circle.fill" : "checkmark.circle.fill"
        )
        .font(.caption2.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.12), in: .capsule)
        .overlay {
            Capsule().strokeBorder(tint.opacity(0.2), lineWidth: 0.75)
        }
    }
}

enum APIKeyOwnerText {
    static func title(user: User?, userID: String?) -> String {
        if let user { return user.displayUsername }
        guard let userID, !userID.isEmpty else { return "System managed" }
        return "User \(String(userID.prefix(8)))"
    }

    static func detail(user: User?, userID: String?) -> String {
        if let user {
            if user.displayUsername == user.username { return user.username }
            return "\(user.displayUsername) (@\(user.username))"
        }
        guard let userID, !userID.isEmpty else { return "System managed" }
        return userID
    }
}

enum APIKeyDateText {
    static func expiration(_ date: Date?) -> String {
        guard let date else { return "Never expires" }
        return "Expires \(date.formatted(date: .abbreviated, time: .omitted))"
    }

    static func lastUsed(_ date: Date?) -> String {
        guard let date else { return "Never" }
        return date.formatted(.relative(presentation: .named))
    }
}
