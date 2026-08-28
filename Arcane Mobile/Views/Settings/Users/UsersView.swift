import SwiftUI
import Arcane

struct UsersView: View {
    private static let pageSize = 50

    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @State private var users: [User] = []
    @State private var pendingDeleteUser: User?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var actionErrorMessage: String?
    @State private var showCreateSheet = false
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var pagination = ProgressivePaginationState()
    @State private var isLoadingMore = false
    @State private var loadMoreError: String?

    var body: some View {
        Group {
            if isLoading && users.isEmpty {
                ProgressView("Loading users...").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage, users.isEmpty {
                ContentUnavailableView(
                    "Couldn't Load Users",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else if users.isEmpty {
                ContentUnavailableView {
                    Label("No Users", systemImage: "person.slash")
                } description: {
                    Text("Add a user to give someone else access to this Arcane server.")
                } actions: {
                    Button("Add User") { showCreateSheet = true }
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ResourceCountSectionHeader(
                            "Users",
                            loadedCount: users.count,
                            totalCount: pagination.totalItems,
                            hasMore: pagination.hasMore
                        )

                        ForEach(users) { user in
                            userLink(user)
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
        .navigationTitle("Users")
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search users"
        )
        .debounce(searchText, for: .milliseconds(200), into: $debouncedSearchText)
        .onChange(of: debouncedSearchText) {
            Task { await loadUsers(refresh: true) }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                NavigationLink {
                    UserSettingsView()
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("User Settings")
            }
            if #available(iOS 26, *) {
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showCreateSheet = true } label: { Image(systemName: "plus") }.accessibilityLabel("Add User")
            }
        }
        .task { await loadUsers() }
        .refreshable { await loadUsers(refresh: true) }
        .sheet(isPresented: $showCreateSheet) {
            CreateUserView {
                if let cached = manager.cached {
                    await cached.invalidateGlobal(paths: ["users", "users/*"])
                }
                await loadUsers(refresh: true)
            }
        }
        .alert(
            "Couldn't Delete User",
            isPresented: Binding(
                get: { actionErrorMessage != nil },
                set: { if !$0 { actionErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { actionErrorMessage = nil }
        } message: {
            Text(actionErrorMessage ?? "")
        }
        .deleteConfirmation(
            item: $pendingDeleteUser,
            title: { _ in "Delete User" },
            message: { "Delete the user “\($0.username)”? This permanently revokes their access." },
            icon: "trash",
            confirmTitle: "Delete"
        ) { user in
            Task { await deleteUser(user) }
        }
    }

    private func userLink(_ user: User) -> some View {
        NavigationLink(destination: UserDetailView(user: user, onUpdate: { await loadUsers() })) {
            UserRow(user: user)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(.rect)
        }
        .cardRowLinkStyle()
        .dashboardCardBackground(cornerRadius: Radius.standard)
        .contextMenu {
            Button(role: .destructive) {
                pendingDeleteUser = user
            } label: {
                DestructiveLabel(text: "Delete")
            }
            .tint(.red)
        }
    }

    private func loadUsers(refresh: Bool = false) async {
        guard let client = manager.client else { return }
        let generation = pagination.reset()
        isLoadingMore = false
        if users.isEmpty { isLoading = true }
        errorMessage = nil
        loadMoreError = nil
        defer {
            if pagination.accepts(generation) {
                isLoading = false
            }
        }
        do {
            let response = try await client.users.listPaginated(
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
            let response = try await client.users.listPaginated(
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
        _ response: PaginatedResponse<User>,
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
        users = PaginationLoader.merge(current: users, incoming: response.data, reset: reset)
        loadMoreError = nil
    }

    private func deleteUser(_ user: User) async {
        guard let client = manager.client else { return }
        do {
            let _: DataResponse<String> = try await client.rest.delete("users/\(user.id)")
            withAnimation {
                users.removeAll { $0.id == user.id }
            }
            if let cached = manager.cached {
                await cached.invalidateGlobal(paths: ["users", "users/*"])
            }
            await loadUsers(refresh: true)
        } catch {
            actionErrorMessage = friendlyErrorMessage(error)
        }
    }
}

struct UserRow: View {
    let user: User

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.circle.fill")
                .font(.title2)
                .foregroundStyle(user.isAdmin ? .indigo : .blue)
                .frame(width: 40, height: 40)
                .glassEffectCompat(in: .circle)

            VStack(alignment: .leading, spacing: 3) {
                Text(user.displayUsername).font(.headline)
                if let email = user.email {
                    Text(email).font(.caption).foregroundStyle(.secondary)
                }
            }

            Spacer()

            if user.isAdmin {
                Text("Admin")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.indigo, in: .capsule)
            }
        }
        .padding(.vertical, 2)
    }
}
