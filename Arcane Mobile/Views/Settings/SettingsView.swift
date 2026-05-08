import SwiftUI
import Arcane

struct SettingsView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @State private var showLogoutConfirm = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let user = manager.currentUser {
                        AccountSummaryRow(user: user)
                    }
                    Button(role: .destructive) {
                        showLogoutConfirm = true
                    } label: {
                        Label("Sign Out", systemImage: "arrow.right.circle.fill")
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Account")
                }

                Section("Application") {
                    NavigationLink(destination: AppSettingsView()) {
                        SettingsNavigationRow(
                            title: "App Settings",
                            systemImage: "gearshape.fill",
                            color: .gray
                        )
                    }
                }

                Section("Arcane Server") {
                    LabeledContent("URL", value: manager.serverURL)
                    NavigationLink(destination: EnvironmentsView()) {
                        SettingsNavigationRow(
                            title: "Environments",
                            systemImage: "server.rack",
                            color: .blue
                        )
                    }
                    Button {
                        Task { await manager.logout() }
                    } label: {
                        Label("Change Server", systemImage: "arrow.left.circle")
                            .foregroundStyle(.primary)
                    }
                }

                Section("Infrastructure") {
                    NavigationLink(destination: VolumesView(
                        environmentID: manager.activeEnvironmentID,
                        environmentName: manager.activeEnvironmentName
                    )) {
                        SettingsNavigationRow(
                            title: "Volumes",
                            systemImage: "externaldrive.fill",
                            color: .orange
                        )
                    }
                    NavigationLink(destination: NetworksView(
                        environmentID: manager.activeEnvironmentID,
                        environmentName: manager.activeEnvironmentName
                    )) {
                        SettingsNavigationRow(
                            title: "Networks",
                            systemImage: "network",
                            color: .teal
                        )
                    }
                }

                if manager.currentUser?.isAdmin == true {
                    Section("Administration") {
                        NavigationLink(destination: UsersView()) {
                            SettingsNavigationRow(
                                title: "Users",
                                systemImage: "person.2.fill",
                                color: .blue
                            )
                        }
                        NavigationLink(destination: APIKeysView()) {
                            SettingsNavigationRow(
                                title: "API Keys",
                                systemImage: "key.fill",
                                color: .yellow
                            )
                        }
                    }
                }

            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
            .confirmationDialog("Sign Out", isPresented: $showLogoutConfirm, titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) {
                    Task { await manager.logout() }
                }
            }
        }
    }
}

struct AccountSummaryRow: View {
    let user: ArcaneUser

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "person.circle.fill")
                .font(.largeTitle)
                .foregroundStyle(.tint)
                .frame(width: 52, height: 52)
                .glassEffect(.regular, in: .circle)

            VStack(alignment: .leading, spacing: 3) {
                Text(user.displayUsername)
                    .font(.headline)
                if let email = user.email {
                    Text(email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let roles = user.roles, !roles.isEmpty {
                    Text(roles.joined(separator: ", ").capitalized)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct SettingsNavigationRow: View {
    let title: String
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .frame(width: 28)

            Text(title)
                .font(.body)
        }
    }
}

struct AppSettingsView: View {
    @State private var showCacheCleared = false

    var body: some View {
        List {
            Section("Storage") {
                Button {
                    Task { await ImageCache.shared.clear() }
                    showCacheCleared = true
                } label: {
                    Label("Clear Image Cache", systemImage: "photo.stack")
                        .foregroundStyle(.primary)
                }
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                LabeledContent("Build", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("App Settings")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Image Cache Cleared", isPresented: $showCacheCleared) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("All cached images will be reloaded from the server.")
        }
    }
}

// MARK: - Users View

struct UsersView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @State private var users: [ArcaneUser] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
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
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Users")
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        Button { showCreateSheet = true } label: { Image(systemName: "plus") }
                            .glassEffect()
                        Button { Task { await loadUsers() } } label: { Image(systemName: "arrow.clockwise") }
                            .glassEffect()
                    }
                }
            }
        }
        .task { await loadUsers() }
        .refreshable { await loadUsers() }
        .sheet(isPresented: $showCreateSheet) {
            CreateUserView { await loadUsers() }
        }
    }

    private func loadUsers() async {
        guard let client = manager.client else { return }
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            users = try await client.rest.get("users")
        } catch { errorMessage = friendlyErrorMessage(error) }
    }

    private func deleteUser(_ user: ArcaneUser) async {
        guard let client = manager.client else { return }
        do {
            let _: DataResponse<String> = try await client.rest.delete("users/\(user.id)")
            users.removeAll { $0.id == user.id }
        } catch {}
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
                    .disabled(isSaving)
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
                                        Label("Delete", systemImage: "trash")
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
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        Button { showCreateSheet = true } label: { Image(systemName: "plus") }.glassEffect()
                        Button { Task { await loadKeys() } } label: { Image(systemName: "arrow.clockwise") }.glassEffect()
                    }
                }
            }
        }
        .task { await loadKeys() }
        .refreshable { await loadKeys() }
        .sheet(isPresented: $showCreateSheet) {
            CreateAPIKeyView { keyString in
                createdKey = keyString
                Task { await loadKeys() }
            }
        }
        .sheet(item: Binding(get: { createdKey.map { CreatedKeyWrapper(key: $0) } }, set: { _ in createdKey = nil })) { wrapper in
            NewAPIKeyView(key: wrapper.key)
        }
    }

    private func loadKeys() async {
        guard let client = manager.client else { return }
        isLoading = true
        defer { isLoading = false }
        do { apiKeys = try await client.rest.get("api-keys") } catch {}
    }

    private func deleteKey(_ key: APIKey) async {
        guard let client = manager.client else { return }
        do {
            let _: DataResponse<String> = try await client.rest.delete("api-keys/\(key.id)")
            apiKeys.removeAll { $0.id == key.id }
        } catch {}
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
                        Button {
                            editingRegistry = registry
                        } label: {
                            RegistryRow(registry: registry)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { await deleteRegistry(registry) }
                            } label: {
                                Label("Delete", systemImage: "trash")
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
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    GlassEffectContainer(spacing: 8) {
                        HStack(spacing: 8) {
                            Button { showCreateRegistrySheet = true } label: { Image(systemName: "plus") }.glassEffect()
                            Button { Task { await loadRegistries() } } label: { Image(systemName: "arrow.clockwise") }.glassEffect()
                        }
                    }
                }
            }
        }
        .task {
            guard manager.currentUser?.isAdmin == true else { return }
            await loadRegistries()
        }
        .refreshable {
            guard manager.currentUser?.isAdmin == true else { return }
            await loadRegistries()
        }
        .sheet(isPresented: $showCreateRegistrySheet) {
            RegistryFormView(registry: nil) { await loadRegistries() }
        }
        .sheet(item: $editingRegistry) { registry in
            RegistryFormView(registry: registry) { await loadRegistries() }
        }
    }

    private func loadRegistries() async {
        guard manager.currentUser?.isAdmin == true, let client = manager.client else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            registries = try await client.rest.get("container-registries")
        } catch {}
    }

    private func deleteRegistry(_ registry: ContainerRegistry) async {
        guard manager.currentUser?.isAdmin == true, let client = manager.client else { return }
        do {
            let _: DataResponse<String> = try await client.rest.delete("container-registries/\(registry.id)")
            registries.removeAll { $0.id == registry.id }
        } catch {}
    }
}

struct TemplateRegistriesView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @State private var registries: [TemplateRegistry] = []
    @State private var isLoading = false
    @State private var showCreateSheet = false
    @State private var showBrowser = false
    @State private var editingRegistry: TemplateRegistry?

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
                        Button {
                            editingRegistry = registry
                        } label: {
                            TemplateRegistryRow(registry: registry)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { await deleteTemplateRegistry(registry) }
                            } label: {
                                Label("Delete", systemImage: "trash")
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
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    GlassEffectContainer(spacing: 8) {
                        HStack(spacing: 8) {
                            Button { showBrowser = true } label: { Image(systemName: "doc.text.magnifyingglass") }.glassEffect()
                            Button { showCreateSheet = true } label: { Image(systemName: "plus") }.glassEffect()
                            Button { Task { await loadRegistries() } } label: { Image(systemName: "arrow.clockwise") }.glassEffect()
                        }
                    }
                }
            }
        }
        .task {
            guard manager.currentUser?.isAdmin == true else { return }
            await loadRegistries()
        }
        .refreshable {
            guard manager.currentUser?.isAdmin == true else { return }
            await loadRegistries()
        }
        .sheet(isPresented: $showCreateSheet) {
            TemplateRegistryFormView(registry: nil) { await loadRegistries() }
        }
        .sheet(isPresented: $showBrowser) {
            TemplateBrowserView()
        }
        .sheet(item: $editingRegistry) { registry in
            TemplateRegistryFormView(registry: registry) { await loadRegistries() }
        }
    }

    private func loadRegistries() async {
        guard manager.currentUser?.isAdmin == true, let client = manager.client else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            registries = try await client.rest.get("templates/registries")
        } catch {}
    }

    private func deleteTemplateRegistry(_ registry: TemplateRegistry) async {
        guard manager.currentUser?.isAdmin == true, let client = manager.client else { return }
        do {
            let _: DataResponse<String> = try await client.rest.delete("templates/registries/\(registry.id)")
            registries.removeAll { $0.id == registry.id }
        } catch {}
    }
}

struct RegistryRow: View {
    let registry: ContainerRegistry
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox.fill")
                .font(.title3).foregroundStyle(.blue)
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
                    Text(error).font(.caption2).foregroundStyle(.red).lineLimit(1)
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
    @State private var registryType = "custom"
    @State private var awsAccessKeyId = ""
    @State private var awsSecretAccessKey = ""
    @State private var awsRegion = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var isEditing: Bool { registry != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Registry Details") {
                    TextField("URL (e.g. registry.example.com)", text: $url)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Description", text: $description)
                    TextField("Type", text: $registryType)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("Enabled", isOn: $enabled)
                    Toggle("Insecure", isOn: $insecure)
                }

                Section("Credentials (optional)") {
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField(isEditing ? "New token or password" : "Token or password", text: $token)
                }

                Section("AWS ECR (optional)") {
                    TextField("Access Key ID", text: $awsAccessKeyId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField(isEditing ? "New Secret Access Key" : "Secret Access Key", text: $awsSecretAccessKey)
                    TextField("Region", text: $awsRegion)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                if let error = errorMessage {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
            }
            .navigationTitle(isEditing ? "Edit Registry" : "Add Registry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Add") { Task { await saveRegistry() } }
                        .disabled(url.isEmpty || isLoading)
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
                        .disabled(name.isEmpty || url.isEmpty || isLoading)
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
        return groups.keys.sorted().map { ($0, groups[$0] ?? []) }
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
                                ForEach(templates.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { template in
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
    let template: ComposeTemplate

    @State private var content: ComposeTemplateContent?
    @State private var composeContent = ""
    @State private var envContent = ""
    @State private var selectedTab = 0
    @State private var isLoading = false
    @State private var errorMessage: String?

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
