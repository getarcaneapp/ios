import SwiftUI
import Arcane

struct UsersView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @State private var users: [User] = []
    @State private var pendingDeleteUser: User?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var actionErrorMessage: String?
    @State private var showCreateSheet = false

    var body: some View {
        Group {
            if isLoading && users.isEmpty {
                ProgressView("Loading users...").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if users.isEmpty {
                ContentUnavailableView {
                    Label("No Users", systemImage: "person.slash")
                } description: {
                    Text("Add a user to give someone else access to this Arcane server.")
                } actions: {
                    Button("Add User") { showCreateSheet = true }
                }
            } else {
                List {
                    ForEach(users) { user in
                        NavigationLink(destination: UserDetailView(user: user, onUpdate: { await loadUsers() })) {
                            UserRow(user: user)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button {
                                pendingDeleteUser = user
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .tint(.red)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Users")
        .toolbar {
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

    private func loadUsers(refresh: Bool = false) async {
        guard let cached = manager.cached else { return }
        if users.isEmpty { isLoading = true }
        errorMessage = nil
        defer { isLoading = false }
        do {
            if let result: [User] = try await cached.getListGlobal(
                "users", elementType: User.self, policy: .users,
                refresh: refresh,
                onFresh: { fresh in users = fresh }
            ) {
                users = result
            }
        } catch { errorMessage = friendlyErrorMessage(error) }
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

