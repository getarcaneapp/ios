import SwiftUI
import Arcane

struct SettingsView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @State private var showLogoutConfirm = false
    @State private var showChangeServerConfirm = false
    @State private var volumeSizeBytes: Int64? = nil
    @State private var loadingVolumeSize = false

    private var isAdmin: Bool { manager.currentUser?.isAdmin == true }

    var body: some View {
        NavigationStack {
            List {
                serverSection
                managementSection
                resourcesSection
                swarmSection
                administrationSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink {
                        AppSettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("App Settings")
                }
                ToolbarSpacer(.fixed, placement: .navigationBarTrailing)
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(role: .destructive) {
                        showLogoutConfirm = true
                    } label: {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .foregroundStyle(.red)
                    }
                    .accessibilityLabel("Sign Out")
                }
            }
            .task {
                await loadVolumeSize()
            }
            .alert("Sign Out", isPresented: $showLogoutConfirm) {
                Button("Sign Out", role: .destructive) {
                    Task { await manager.logout() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You'll be signed out of this server.")
            }
        }
    }

    private func loadVolumeSize() async {
        guard let client = manager.client, let cached = manager.cached,
              volumeSizeBytes == nil, !loadingVolumeSize else { return }
        loadingVolumeSize = true
        defer { loadingVolumeSize = false }
        do {
            let path = client.rest.environmentPath(manager.activeEnvironmentID, "volumes/sizes")
            if let sizes: [VolumeSizeInfo] = try await cached.get(
                path, as: [VolumeSizeInfo].self, policy: .volumes,
                envID: manager.activeEnvironmentID,
                onFresh: { fresh in
                    volumeSizeBytes = fresh.reduce(Int64(0)) { $0 + $1.size }
                }
            ) {
                volumeSizeBytes = sizes.reduce(Int64(0)) { $0 + $1.size }
            }
        } catch {
            // Slow / unsupported on some hosts — leave blank silently.
        }
    }

    // MARK: - Sections

    private var pinnedTabs: Set<AppTab> {
        _ = NavTabsStore.shared.version
        return Set(NavTabsStore.shared.pinnedTabs)
    }

    private func visibleTabs(in section: AppTab.Section) -> [AppTab] {
        AppTab.allCases.filter { tab in
            tab.section == section
                && !pinnedTabs.contains(tab)
                && (isAdmin || !tab.requiresAdmin)
        }
    }

    @ViewBuilder
    private var managementSection: some View {
        let tabs = visibleTabs(in: .management)
        if !tabs.isEmpty {
            Section("Management") {
                ForEach(tabs) { tab in
                    NavigationLink(destination: appTabDestination(tab, manager: manager, selectedTab: .constant(""))) {
                        SettingsRow(
                            title: tab.title,
                            systemImage: tab.systemImage,
                            color: tab.iconColor
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var swarmSection: some View {
        let tabs = visibleTabs(in: .swarm)
        if !tabs.isEmpty {
            Section("Swarm") {
                ForEach(tabs) { tab in
                    NavigationLink(destination: appTabDestination(tab, manager: manager, selectedTab: .constant(""))) {
                        SettingsRow(
                            title: tab.title,
                            systemImage: tab.systemImage,
                            color: tab.iconColor
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var serverSection: some View {
        Section {
            NavigationLink(destination: EnvironmentsView()) {
                SettingsRow(
                    title: "Active Environment",
                    subtitle: manager.activeEnvironmentName,
                    systemImage: "server.rack",
                    color: .blue
                )
            }
            Button {
                showChangeServerConfirm = true
            } label: {
                HStack {
                    SettingsRow(
                        title: "Server",
                        subtitle: manager.serverURL.isEmpty ? "Not configured" : manager.serverURL,
                        systemImage: "link",
                        color: .blue,
                        titleColor: .primary
                    )
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .confirmationDialog(
                "Change Server?",
                isPresented: $showChangeServerConfirm,
                titleVisibility: .visible
            ) {
                Button("Change Server", role: .destructive) {
                    Task { await manager.logout() }
                }
            } message: {
                Text("You'll be signed out and asked for a new server URL.")
            }
        } header: {
            Text("Server")
        } footer: {
            if let user = manager.currentUser {
                Text("Signed in as \(user.displayUsername). Tap the server row to switch.")
            } else {
                Text("Tap the server row to switch.")
            }
        }
    }

    @ViewBuilder
    private var resourcesSection: some View {
        let tabs = visibleTabs(in: .resources)
        if !tabs.isEmpty {
            Section("Resources") {
                ForEach(tabs) { tab in
                    NavigationLink(destination: appTabDestination(tab, manager: manager, selectedTab: .constant(""))) {
                        resourceRow(tab)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func resourceRow(_ tab: AppTab) -> some View {
        if tab == .volumes {
            HStack {
                SettingsRow(title: tab.title, systemImage: tab.systemImage, color: tab.iconColor)
                Spacer()
                if let size = volumeSizeBytes {
                    Text(size.byteString)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else if loadingVolumeSize {
                    ProgressView().scaleEffect(0.7)
                }
            }
        } else {
            SettingsRow(title: tab.title, systemImage: tab.systemImage, color: tab.iconColor)
        }
    }

    @ViewBuilder
    private var administrationSection: some View {
        let tabs = visibleTabs(in: .administration)
        if !tabs.isEmpty {
            Section {
                ForEach(tabs) { tab in
                    NavigationLink(destination: appTabDestination(tab, manager: manager, selectedTab: .constant(""))) {
                        SettingsRow(
                            title: tab.title,
                            systemImage: tab.systemImage,
                            color: tab.iconColor
                        )
                    }
                }
            } header: {
                Text("Administration")
            }
        }
    }

}

// MARK: - Reusable rows

struct SettingsRow: View {
    let title: String
    var subtitle: String? = nil
    let systemImage: String
    let color: Color
    var titleColor: Color = .primary

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(titleColor)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }
}

// External-link row with a matching outbound-arrow trailing affordance.
struct SettingsExternalRow: View {
    let title: String
    let systemImage: String
    let color: Color

    var body: some View {
        HStack {
            SettingsRow(title: title, systemImage: systemImage, color: color, titleColor: .primary)
            Spacer()
            Image(systemName: "arrow.up.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }
}

// Kept as an alias for any older callers; prefer SettingsRow.
struct SettingsNavigationRow: View {
    let title: String
    let systemImage: String
    let color: Color

    var body: some View {
        SettingsRow(title: title, systemImage: systemImage, color: color)
    }
}

// MARK: - Users View

struct UsersView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @State private var users: [ArcaneUser] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var actionErrorMessage: String?
    @State private var showCreateSheet = false

    var body: some View {
        Group {
            if isLoading && users.isEmpty {
                ProgressView("Loading users...").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if users.isEmpty {
                ContentUnavailableView("No Users", systemImage: "person.slash", description: Text("No users found"))
            } else {
                List {
                    ForEach(users) { user in
                        NavigationLink(destination: UserDetailView(user: user, onUpdate: { await loadUsers() })) {
                            UserRow(user: user)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { await deleteUser(user) }
                            } label: {
                                DestructiveLabel(text: "Delete")
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Users")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showCreateSheet = true } label: { Image(systemName: "plus") }
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
    }

    private func loadUsers(refresh: Bool = false) async {
        guard let cached = manager.cached else { return }
        if users.isEmpty { isLoading = true }
        errorMessage = nil
        defer { isLoading = false }
        do {
            if let result: [ArcaneUser] = try await cached.getListGlobal(
                "users", elementType: ArcaneUser.self, policy: .users,
                refresh: refresh,
                onFresh: { fresh in users = fresh }
            ) {
                users = result
            }
        } catch { errorMessage = friendlyErrorMessage(error) }
    }

    private func deleteUser(_ user: ArcaneUser) async {
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
    let user: ArcaneUser

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.circle.fill")
                .font(.title2)
                .foregroundStyle(user.isAdmin ? .orange : .blue)
                .frame(width: 40, height: 40)
                .glassEffect(.regular, in: .circle)

            VStack(alignment: .leading, spacing: 3) {
                Text(user.displayUsername).font(.headline)
                if let email = user.email {
                    Text(email).font(.caption).foregroundStyle(.secondary)
                }
            }

            Spacer()

            if user.isAdmin {
                Text("Admin")
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .glassEffect(.regular.tint(.orange), in: .capsule)
            }
        }
        .padding(.vertical, 2)
    }
}

struct UserDetailView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let user: ArcaneUser
    let onUpdate: () async -> Void

    @State private var email: String
    @State private var displayName: String
    @State private var isAdmin: Bool
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(user: ArcaneUser, onUpdate: @escaping () async -> Void) {
        self.user = user
        self.onUpdate = onUpdate
        _email = State(initialValue: user.email ?? "")
        _displayName = State(initialValue: user.displayName ?? "")
        _isAdmin = State(initialValue: user.isAdmin)
    }

    private var hasChanges: Bool {
        email != (user.email ?? "")
            || displayName != (user.displayName ?? "")
            || isAdmin != user.isAdmin
    }

    var body: some View {
        Form {
            Section("User Info") {
                LabeledContent("Username", value: user.displayUsername)
                TextField("Email", text: $email)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                TextField("Display Name", text: $displayName)
            }
            Section("Roles") {
                Toggle("Administrator", isOn: $isAdmin)
            }
            if let error = errorMessage {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            }
        }
        .navigationTitle(user.displayUsername)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await saveUser() } }
                    .disabled(isSaving || !hasChanges)
            }
        }
    }

    private func saveUser() async {
        guard let client = manager.client else { return }
        isSaving = true; errorMessage = nil
        defer { isSaving = false }
        do {
            let body = UpdateUserRequest(
                displayName: displayName.isEmpty ? nil : displayName,
                email: email.isEmpty ? nil : email,
                roles: isAdmin ? ["admin"] : []
            )
            let _: ArcaneUser = try await client.rest.put("users/\(user.id)", body: body)
            await onUpdate()
            dismiss()
        } catch { errorMessage = friendlyErrorMessage(error) }
    }
}

struct CreateUserView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let onSuccess: () async -> Void

    @State private var username = ""
    @State private var password = ""
    @State private var email = ""
    @State private var isAdmin = false
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Credentials") {
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                }
                Section("Profile") {
                    TextField("Email (optional)", text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                }
                Section("Roles") {
                    Toggle("Administrator", isOn: $isAdmin)
                }
                if let error = errorMessage {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
            }
            .navigationTitle("Create User")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await createUser() } }
                        .disabled(username.isEmpty || password.isEmpty || isLoading)
                }
            }
        }
    }

    private func createUser() async {
        guard let client = manager.client else { return }
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            let body = CreateUserRequest(
                displayName: nil,
                email: email.isEmpty ? nil : email,
                password: password,
                roles: isAdmin ? ["admin"] : ["user"],
                username: username
            )
            let _: ArcaneUser = try await client.rest.post("users", body: body)
            await onSuccess(); dismiss()
        } catch { errorMessage = friendlyErrorMessage(error) }
    }
}

// MARK: - API Keys View

struct APIKeysView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @State private var apiKeys: [APIKey] = []
    @State private var isLoading = false
    @State private var showCreateSheet = false
    @State private var createdKey: String?
    @State private var actionErrorMessage: String?

    var body: some View {
        Group {
            if isLoading && apiKeys.isEmpty {
                ProgressView("Loading API keys...").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if apiKeys.isEmpty {
                ContentUnavailableView("No API Keys", systemImage: "key.slash", description: nil)
            } else {
                List {
                    ForEach(apiKeys) { key in
                        APIKeyRow(apiKey: key)
                            .swipeActions(edge: .trailing) {
                                if key.isProtected != true {
                                    Button(role: .destructive) {
                                        Task { await deleteKey(key) }
                                    } label: {
                                        DestructiveLabel(text: "Delete")
                                    }
                                }
                            }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("API Keys")
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
        defer { isLoading = false }
        do {
            if let result: [APIKey] = try await cached.getListGlobal(
                "api-keys", elementType: APIKey.self, policy: .apiKeys,
                refresh: refresh,
                onFresh: { fresh in apiKeys = fresh }
            ) {
                apiKeys = result
            }
        } catch {}
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

struct NewAPIKeyView: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let key: String

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "key.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.yellow)
                    .padding(24)
                    .glassEffect(.regular, in: .circle)

                Text("Save Your API Key")
                    .font(.title2.bold())

                Text("This key will only be shown once. Make sure to save it somewhere safe.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 32)

                Text(key)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(16)
                    .glassEffect(.regular, in: .rect(cornerRadius: 12))
                    .padding(.horizontal, 24)

                Button {
                    UIPasteboard.general.string = key
                } label: {
                    Label("Copy to Clipboard", systemImage: "doc.on.clipboard")
                        .frame(maxWidth: .infinity)
                        .padding()
                }
                .buttonStyle(.glassProminent)
                .padding(.horizontal, 24)

                Spacer()
            }
            .padding(.top, 32)
            .navigationTitle("API Key Created")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct CreateAPIKeyView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let onCreated: (String) -> Void

    @State private var name = ""
    @State private var description = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Key Details") {
                    TextField("Name", text: $name)
                    TextField("Description (optional)", text: $description)
                }
                if let error = errorMessage {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
            }
            .navigationTitle("Create API Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await createKey() } }
                        .disabled(name.isEmpty || isLoading)
                }
            }
        }
    }

    private func createKey() async {
        guard let client = manager.client else { return }
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            let body = CreateAPIKeyRequest(description: description.isEmpty ? nil : description, name: name)
            let created: APIKeyCreated = try await client.rest.post("api-keys", body: body)
            onCreated(created.key)
            dismiss()
        } catch { errorMessage = friendlyErrorMessage(error) }
    }
}

// MARK: - Container Registries View

struct ContainerRegistriesView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @State private var registries: [ContainerRegistry] = []
    @State private var isLoading = false
    @State private var showCreateRegistrySheet = false
    @State private var editingRegistry: ContainerRegistry?
    @State private var actionErrorMessage: String?

    var body: some View {
        Group {
            if manager.currentUser?.isAdmin != true {
                ContentUnavailableView("Admin Required", systemImage: "lock.fill", description: Text("Only administrators can manage container registries."))
            } else if isLoading && registries.isEmpty {
                ProgressView("Loading registries...").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if registries.isEmpty {
                ContentUnavailableView("No Container Registries", systemImage: "shippingbox.slash", description: nil)
            } else {
                List {
                    ForEach(registries) { registry in
                        PressableRegistryRow(
                            registry: registry,
                            onEdit: { editingRegistry = registry },
                            onDelete: { Task { await deleteRegistry(registry) } }
                        )
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { await deleteRegistry(registry) }
                            } label: {
                                DestructiveLabel(text: "Delete")
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Container Registries")
        .toolbar {
            if manager.currentUser?.isAdmin == true {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showCreateRegistrySheet = true } label: { Image(systemName: "plus") }
                }
            }
        }
        .task {
            guard manager.currentUser?.isAdmin == true else { return }
            await loadRegistries()
        }
        .refreshable {
            guard manager.currentUser?.isAdmin == true else { return }
            await loadRegistries(refresh: true)
        }
        .sheet(isPresented: $showCreateRegistrySheet) {
            RegistryFormView(registry: nil) {
                if let cached = manager.cached {
                    await cached.invalidateGlobal(paths: ["container-registries", "container-registries/*"])
                }
                await loadRegistries(refresh: true)
            }
        }
        .sheet(item: $editingRegistry) { registry in
            RegistryFormView(registry: registry) {
                if let cached = manager.cached {
                    await cached.invalidateGlobal(paths: ["container-registries", "container-registries/*"])
                }
                await loadRegistries(refresh: true)
            }
        }
        .alert(
            "Couldn't Delete Registry",
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

    private func loadRegistries(refresh: Bool = false) async {
        guard manager.currentUser?.isAdmin == true, let cached = manager.cached else { return }
        if registries.isEmpty { isLoading = true }
        defer { isLoading = false }
        do {
            if let result: [ContainerRegistry] = try await cached.getListGlobal(
                "container-registries", elementType: ContainerRegistry.self,
                policy: .registries, refresh: refresh,
                onFresh: { fresh in registries = fresh }
            ) {
                registries = result
            }
        } catch {}
    }

    private func deleteRegistry(_ registry: ContainerRegistry) async {
        guard manager.currentUser?.isAdmin == true, let client = manager.client else { return }
        do {
            let _: DataResponse<String> = try await client.rest.delete("container-registries/\(registry.id)")
            withAnimation {
                registries.removeAll { $0.id == registry.id }
            }
            if let cached = manager.cached {
                await cached.invalidateGlobal(paths: ["container-registries", "container-registries/*"])
            }
        } catch {
            actionErrorMessage = friendlyErrorMessage(error)
        }
    }
}

struct TemplateRegistriesView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @State private var registries: [TemplateRegistry] = []
    @State private var isLoading = false
    @State private var showCreateSheet = false
    @State private var showBrowser = false
    @State private var editingRegistry: TemplateRegistry?
    @State private var actionErrorMessage: String?

    var body: some View {
        Group {
            if manager.currentUser?.isAdmin != true {
                ContentUnavailableView("Admin Required", systemImage: "lock.fill", description: Text("Only administrators can manage template registries."))
            } else if isLoading && registries.isEmpty {
                ProgressView("Loading template registries...").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if registries.isEmpty {
                ContentUnavailableView("No Template Registries", systemImage: "doc.text", description: nil)
            } else {
                List {
                    ForEach(registries) { registry in
                        PressableTemplateRegistryRow(
                            registry: registry,
                            onEdit: { editingRegistry = registry },
                            onDelete: { Task { await deleteTemplateRegistry(registry) } }
                        )
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { await deleteTemplateRegistry(registry) }
                            } label: {
                                DestructiveLabel(text: "Delete")
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Template Registries")
        .toolbar {
            if manager.currentUser?.isAdmin == true {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showBrowser = true } label: { Image(systemName: "doc.text.magnifyingglass") }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showCreateSheet = true } label: { Image(systemName: "plus") }
                }
            }
        }
        .task {
            guard manager.currentUser?.isAdmin == true else { return }
            await loadRegistries()
        }
        .refreshable {
            guard manager.currentUser?.isAdmin == true else { return }
            await loadRegistries(refresh: true)
        }
        .sheet(isPresented: $showCreateSheet) {
            TemplateRegistryFormView(registry: nil) {
                if let cached = manager.cached {
                    await cached.invalidateGlobal(paths: ["templates/registries", "templates/registries/*", "templates/all"])
                }
                await loadRegistries(refresh: true)
            }
        }
        .sheet(isPresented: $showBrowser) {
            TemplateBrowserView()
        }
        .sheet(item: $editingRegistry) { registry in
            TemplateRegistryFormView(registry: registry) {
                if let cached = manager.cached {
                    await cached.invalidateGlobal(paths: ["templates/registries", "templates/registries/*", "templates/all"])
                }
                await loadRegistries(refresh: true)
            }
        }
        .alert(
            "Couldn't Delete Registry",
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

    private func loadRegistries(refresh: Bool = false) async {
        guard manager.currentUser?.isAdmin == true, let cached = manager.cached else { return }
        if registries.isEmpty { isLoading = true }
        defer { isLoading = false }
        do {
            if let result: [TemplateRegistry] = try await cached.getListGlobal(
                "templates/registries", elementType: TemplateRegistry.self,
                policy: .templates, refresh: refresh,
                onFresh: { fresh in registries = fresh }
            ) {
                registries = result
            }
        } catch {}
    }

    private func deleteTemplateRegistry(_ registry: TemplateRegistry) async {
        guard manager.currentUser?.isAdmin == true, let client = manager.client else { return }
        do {
            let _: DataResponse<String> = try await client.rest.delete("templates/registries/\(registry.id)")
            withAnimation {
                registries.removeAll { $0.id == registry.id }
            }
            if let cached = manager.cached {
                await cached.invalidateGlobal(paths: ["templates/registries", "templates/registries/*", "templates/all"])
            }
        } catch {
            actionErrorMessage = friendlyErrorMessage(error)
        }
    }
}

struct RegistryRow: View {
    let registry: ContainerRegistry
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox.fill")
                .font(.title3).foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
                .glassEffect(.regular, in: .circle)
            VStack(alignment: .leading, spacing: 3) {
                Text(registry.name ?? registry.id).font(.headline)
                Text(registry.url).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !registry.enabled {
                Text("Disabled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct PressableRegistryRow: View {
    let registry: ContainerRegistry
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onEdit) {
            RegistryRow(registry: registry)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(action: onEdit) {
                Label("Edit", systemImage: "pencil")
            }
            Button(role: .destructive, action: onDelete) {
                DestructiveLabel(text: "Delete")
            }
            .tint(.red)
        } preview: {
            RowPreviewCard(
                icon: "shippingbox.fill",
                iconColor: .accentColor,
                title: registry.name ?? registry.id,
                badges: [
                    .init(text: registry.enabled ? "Enabled" : "Disabled",
                          color: registry.enabled ? .green : .secondary)
                ],
                details: [
                    .init(icon: "link", label: "URL", value: registry.url)
                ]
            )
        }
    }
}

struct TemplateRegistryRow: View {
    let registry: TemplateRegistry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text.fill")
                .font(.title3).foregroundStyle(.indigo)
                .frame(width: 36, height: 36)
                .glassEffect(.regular, in: .circle)
            VStack(alignment: .leading, spacing: 3) {
                Text(registry.name).font(.headline)
                Text(registry.url).font(.caption).foregroundStyle(.secondary)
                if let error = registry.lastFetchError, !error.isEmpty {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if !registry.enabled {
                Text("Disabled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct PressableTemplateRegistryRow: View {
    let registry: TemplateRegistry
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onEdit) {
            TemplateRegistryRow(registry: registry)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(action: onEdit) {
                Label("Edit", systemImage: "pencil")
            }
            Button(role: .destructive, action: onDelete) {
                DestructiveLabel(text: "Delete")
            }
            .tint(.red)
        } preview: {
            RowPreviewCard(
                icon: "doc.text.fill",
                iconColor: .indigo,
                title: registry.name,
                badges: [
                    .init(text: registry.enabled ? "Enabled" : "Disabled",
                          color: registry.enabled ? .green : .secondary)
                ],
                details: detailRows
            )
        }
    }

    private var detailRows: [RowPreviewCard.PreviewDetail] {
        var rows: [RowPreviewCard.PreviewDetail] = [
            .init(icon: "link", label: "URL", value: registry.url)
        ]
        if let error = registry.lastFetchError, !error.isEmpty {
            rows.append(.init(icon: "exclamationmark.triangle", label: "Last Fetch Error", value: error))
        }
        return rows
    }
}

struct RegistryFormView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let registry: ContainerRegistry?
    let onSuccess: () async -> Void

    @State private var url = ""
    @State private var username = ""
    @State private var token = ""
    @State private var description = ""
    @State private var enabled = true
    @State private var insecure = false
    @State private var registryType = "generic"
    @State private var awsAccessKeyId = ""
    @State private var awsSecretAccessKey = ""
    @State private var awsRegion = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var isEditing: Bool { registry != nil }
    private var isAWS: Bool { registryType == "ecr" }

    // Picker selects between generic and ecr; legacy "custom" maps to generic.
    private var typeBinding: Binding<String> {
        Binding(
            get: { registryType == "ecr" ? "ecr" : "generic" },
            set: { registryType = $0 }
        )
    }

    // For new registries, the URL field is required and Save enables once it's set.
    // For edits, Save only enables when something actually differs from the loaded
    // record (token/awsSecretAccessKey count as changed if any value was typed).
    private var hasChanges: Bool {
        guard let registry else { return !url.isEmpty }
        let typeMatch = registryType == registry.registryType
            || (typeBinding.wrappedValue == "generic"
                && (registry.registryType == "generic" || registry.registryType == "custom"))
        return url != registry.url
            || username != registry.username
            || description != (registry.description ?? "")
            || enabled != registry.enabled
            || insecure != registry.insecure
            || !typeMatch
            || awsAccessKeyId != (registry.awsAccessKeyId ?? "")
            || awsRegion != (registry.awsRegion ?? "")
            || !token.isEmpty
            || !awsSecretAccessKey.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Registry Details") {
                    TextField("URL (e.g. registry.example.com)", text: $url)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Description", text: $description)
                    Picker("Type", selection: typeBinding) {
                        Text("Generic").tag("generic")
                        Text("AWS ECR").tag("ecr")
                    }
                    Toggle("Enabled", isOn: $enabled)
                    Toggle("Insecure", isOn: $insecure)
                }

                if !isAWS {
                    Section("Credentials (optional)") {
                        TextField("Username", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField(isEditing ? "New token or password" : "Token or password", text: $token)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if isAWS {
                    Section("AWS ECR") {
                        TextField("Access Key ID", text: $awsAccessKeyId)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField(isEditing ? "New Secret Access Key" : "Secret Access Key", text: $awsSecretAccessKey)
                        TextField("Region (e.g. us-east-1)", text: $awsRegion)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if let error = errorMessage {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isAWS)
            .navigationTitle(isEditing ? "Edit Registry" : "Add Registry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Add") { Task { await saveRegistry() } }
                        .disabled(url.isEmpty || isLoading || !hasChanges)
                }
            }
            .onAppear { populateFields() }
        }
    }

    private func populateFields() {
        guard let registry else { return }
        url = registry.url
        username = registry.username
        description = registry.description ?? ""
        enabled = registry.enabled
        insecure = registry.insecure
        registryType = registry.registryType
        awsAccessKeyId = registry.awsAccessKeyId ?? ""
        awsRegion = registry.awsRegion ?? ""
    }

    private func saveRegistry() async {
        guard let client = manager.client else { return }
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            if let registry {
                let body = UpdateContainerRegistryRequest(
                    awsAccessKeyId: awsAccessKeyId.nilIfEmpty,
                    awsRegion: awsRegion.nilIfEmpty,
                    awsSecretAccessKey: awsSecretAccessKey.nilIfEmpty,
                    description: description.nilIfEmpty,
                    enabled: enabled,
                    insecure: insecure,
                    registryType: registryType.nilIfEmpty,
                    token: token.nilIfEmpty,
                    url: url,
                    username: username.nilIfEmpty
                )
                let _: ContainerRegistry = try await client.rest.put("container-registries/\(registry.id)", body: body)
            } else {
                let body = CreateContainerRegistryRequest(
                    awsAccessKeyId: awsAccessKeyId,
                    awsRegion: awsRegion,
                    awsSecretAccessKey: awsSecretAccessKey,
                    description: description.nilIfEmpty,
                    enabled: enabled,
                    insecure: insecure,
                    registryType: registryType.isEmpty ? "custom" : registryType,
                    token: token,
                    url: url,
                    username: username
                )
                let _: ContainerRegistry = try await client.rest.post("container-registries", body: body)
            }
            await onSuccess(); dismiss()
        } catch { errorMessage = friendlyErrorMessage(error) }
    }
}

struct TemplateRegistryFormView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let registry: TemplateRegistry?
    let onSuccess: () async -> Void

    @State private var name = ""
    @State private var url = ""
    @State private var description = ""
    @State private var enabled = true
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var isEditing: Bool { registry != nil }

    private var hasChanges: Bool {
        guard let registry else { return !name.isEmpty || !url.isEmpty }
        return name != registry.name
            || url != registry.url
            || description != registry.description
            || enabled != registry.enabled
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Template Registry") {
                    TextField("Name", text: $name)
                    TextField("URL", text: $url)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Description", text: $description)
                    Toggle("Enabled", isOn: $enabled)
                }

                if let error = errorMessage {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
            }
            .navigationTitle(isEditing ? "Edit Template Registry" : "Add Template Registry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Add") { Task { await saveRegistry() } }
                        .disabled(name.isEmpty || url.isEmpty || isLoading || !hasChanges)
                }
            }
            .onAppear { populateFields() }
        }
    }

    private func populateFields() {
        guard let registry else { return }
        name = registry.name
        url = registry.url
        description = registry.description
        enabled = registry.enabled
    }

    private func saveRegistry() async {
        guard let client = manager.client else { return }
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            if let registry {
                let body = UpdateTemplateRegistryRequest(
                    description: description,
                    enabled: enabled,
                    name: name,
                    url: url
                )
                let _: TemplateRegistry = try await client.rest.put("templates/registries/\(registry.id)", body: body)
            } else {
                let body = CreateTemplateRegistryRequest(
                    description: description,
                    enabled: enabled,
                    name: name,
                    url: url
                )
                let _: TemplateRegistry = try await client.rest.post("templates/registries", body: body)
            }
            await onSuccess(); dismiss()
        } catch { errorMessage = friendlyErrorMessage(error) }
    }
}

struct TemplateBrowserView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @State private var templates: [ComposeTemplate] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var groupedTemplates: [(String, [ComposeTemplate])] {
        let groups = Dictionary(grouping: templates) { template in
            template.registry?.name ?? (template.isRemote ? "Remote" : "Local")
        }
        return groups.keys.sorted().map { key in
            let sorted = (groups[key] ?? []).sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            return (key, sorted)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && templates.isEmpty {
                    ProgressView("Loading templates...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage, templates.isEmpty {
                    ContentUnavailableView("Error", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
                } else if templates.isEmpty {
                    ContentUnavailableView("No Templates", systemImage: "doc.text", description: nil)
                } else {
                    List {
                        ForEach(groupedTemplates, id: \.0) { registryName, templates in
                            Section(registryName) {
                                ForEach(templates) { template in
                                    NavigationLink(destination: TemplatePreviewView(template: template)) {
                                        TemplateRow(template: template)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Templates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { Task { await loadTemplates() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .task { await loadTemplates() }
            .refreshable { await loadTemplates() }
        }
    }

    private func loadTemplates() async {
        guard let client = manager.client else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            templates = try await client.rest.get("templates/all")
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }
}

struct TemplateRow: View {
    let template: ComposeTemplate

    var body: some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: template.iconUrl, size: 36) {
                Image(systemName: template.isRemote ? "cloud.fill" : "doc.text.fill")
                    .font(.title3)
                    .foregroundStyle(template.isRemote ? .blue : .indigo)
                    .frame(width: 36, height: 36)
                    .glassEffect(.regular, in: .circle)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(template.name)
                    .font(.headline)
                Text(template.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

struct TemplatePreviewView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let template: ComposeTemplate

    @State private var content: ComposeTemplateContent?
    @State private var composeContent = ""
    @State private var envContent = ""
    @State private var selectedTab = 0
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showDeploy = false

    var body: some View {
        Group {
            if isLoading && content == nil {
                ProgressView("Loading template...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    Picker("File", selection: $selectedTab) {
                        Text("compose.yml").tag(0)
                        Text(".env").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.vertical, 8)

                    Divider()

                    if selectedTab == 0 {
                        CodeEditorView(text: $composeContent, language: .yaml)
                    } else {
                        CodeEditorView(text: $envContent, language: .env)
                    }
                }
            }
        }
        .navigationTitle(template.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showDeploy = true
                } label: {
                    Label("Deploy", systemImage: "play.circle.fill")
                }
                .disabled(content == nil)
            }
        }
        .sheet(isPresented: $showDeploy) {
            CreateProjectView(
                environmentID: manager.activeEnvironmentID,
                prefilledName: template.name
                    .lowercased()
                    .replacingOccurrences(of: " ", with: "-"),
                prefilledCompose: composeContent,
                prefilledEnv: envContent,
                templateLabel: template.name
            ) {
                showDeploy = false
                dismiss()
            }
        }
        .task { await loadContent() }
        .overlay(alignment: .bottom) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding()
            }
        }
    }

    private func loadContent() async {
        guard let client = manager.client else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let loaded: ComposeTemplateContent = try await client.rest.get("templates/\(template.id)/content")
            content = loaded
            composeContent = loaded.content
            envContent = loaded.envContent
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
