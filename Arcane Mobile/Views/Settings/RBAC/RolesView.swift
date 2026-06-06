import SwiftUI
import Arcane

struct RolesView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @State private var roles: [Role] = []
    @State private var manifest: PermissionsManifest?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var actionErrorMessage: String?
    @State private var showCreateSheet = false
    @State private var pendingDeleteRole: Role?

    private var rbacAvailable: Bool {
        manager.serverCapabilities?.supportsRoleManagement == true
    }

    var body: some View {
        Group {
            if !rbacAvailable {
                ContentUnavailableView(
                    "Roles Not Available",
                    systemImage: "lock.slash",
                    description: Text("Role-based access control requires Arcane v2 or newer.")
                )
            } else if !manager.permissions.canManageRoles {
                ContentUnavailableView(
                    "Admin Required",
                    systemImage: "lock.fill",
                    description: Text("You don't have permission to view roles.")
                )
            } else if isLoading && roles.isEmpty {
                ProgressView("Loading roles…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage, roles.isEmpty {
                ContentUnavailableView(
                    "Error",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else {
                List {
                    let builtIns = roles.filter { $0.builtIn }
                    let customs = roles.filter { !$0.builtIn }
                    if !builtIns.isEmpty {
                        Section("Built-in") {
                            ForEach(builtIns) { role in
                                NavigationLink(destination: RoleDetailView(role: role, manifest: manifest, mode: .readOnly, onUpdate: { await load(refresh: true) })) {
                                    RoleRow(role: role)
                                }
                            }
                        }
                    }
                    if !customs.isEmpty {
                        Section("Custom") {
                            ForEach(customs) { role in
                                NavigationLink(destination: RoleDetailView(role: role, manifest: manifest, mode: .edit, onUpdate: { await load(refresh: true) })) {
                                    RoleRow(role: role)
                                }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        pendingDeleteRole = role
                                    } label: {
                                        DestructiveLabel(text: "Delete")
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Roles")
        .toolbar {
            if rbacAvailable && manager.permissions.canManageRoles {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showCreateSheet = true } label: { Image(systemName: "plus") }
                }
            }
        }
        .task { await load() }
        .refreshable { await load(refresh: true) }
        .sheet(isPresented: $showCreateSheet) {
            NavigationStack {
                RoleDetailView(role: nil, manifest: manifest, mode: .create, onUpdate: { await load(refresh: true) })
            }
        }
        .alert(
            "Couldn't Delete Role",
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
            item: $pendingDeleteRole,
            title: { _ in "Delete Role" },
            message: { "Delete the “\($0.displayName)” role? This cannot be undone." },
            icon: "trash",
            confirmTitle: "Delete"
        ) { role in
            Task { await deleteRole(role) }
        }
    }

    private func load(refresh: Bool = false) async {
        guard rbacAvailable, let client = manager.client else { return }
        if roles.isEmpty { isLoading = true }
        errorMessage = nil
        defer { isLoading = false }
        do {
            async let rolesPage = client.roles.listPaginated(limit: 100)
            async let manifestResp = client.roles.availablePermissions()
            let (page, m) = try await (rolesPage, manifestResp)
            roles = page.data
            manifest = m
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func deleteRole(_ role: Role) async {
        guard let client = manager.client else { return }
        do {
            try await client.roles.delete(id: role.id)
            withAnimation {
                roles.removeAll { $0.id == role.id }
            }
        } catch let ArcaneError.conflict(message) {
            actionErrorMessage = message ?? "This role can't be deleted because it would leave the system with no administrators."
        } catch {
            actionErrorMessage = friendlyErrorMessage(error)
        }
    }
}

struct RoleRow: View {
    let role: Role

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: role.systemImage)
                .font(.title3)
                .foregroundStyle(role.iconColor)
                .frame(width: 40, height: 40)
                .glassEffectCompat(in: .circle)
            VStack(alignment: .leading, spacing: 3) {
                Text(role.displayName).font(.headline)
                if let desc = role.description, !desc.isEmpty {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    Text("\(role.permissions.count) permissions")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if role.assignedUserCount > 0 {
                        Text("·")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text("\(role.assignedUserCount) assigned")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer()
            if role.builtIn {
                Text("Built-in")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.gray.opacity(0.18), in: .capsule)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Role Detail / Create / Edit

struct RoleDetailView: View {
    enum Mode { case create, edit, readOnly }

    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.dismiss) private var dismiss

    let role: Role?
    let manifest: PermissionsManifest?
    let mode: Mode
    let onUpdate: () async -> Void

    @State private var name: String
    @State private var description: String
    @State private var selectedPermissions: Set<String>
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var search: String = ""

    init(role: Role?, manifest: PermissionsManifest?, mode: Mode, onUpdate: @escaping () async -> Void) {
        self.role = role
        self.manifest = manifest
        self.mode = mode
        self.onUpdate = onUpdate
        _name = State(initialValue: role?.name ?? "")
        _description = State(initialValue: role?.description ?? "")
        _selectedPermissions = State(initialValue: Set(role?.permissions ?? []))
    }

    private var isReadOnly: Bool { mode == .readOnly }

    private var hasChanges: Bool {
        guard let role else { return !name.isEmpty && !selectedPermissions.isEmpty }
        return name != role.name
            || description != (role.description ?? "")
            || selectedPermissions != Set(role.permissions)
    }

    var body: some View {
        Form {
            Section("Role Info") {
                if isReadOnly {
                    FormValueRow(title: "Name", value: name)
                    if !description.isEmpty {
                        FormValueRow(title: "Description", value: description)
                    }
                } else {
                    FormTextField(
                        title: "Name",
                        placeholder: "Deploy Operator",
                        text: $name,
                        helper: "Use a short name that explains who this role is for."
                    )
                    FormTextField(
                        title: "Description",
                        placeholder: "Optional",
                        text: $description,
                        axis: .vertical,
                        lineLimit: 2...4
                    )
                }
            }
            if let manifest {
                PermissionPickerView(
                    manifest: manifest,
                    selected: $selectedPermissions,
                    isReadOnly: isReadOnly,
                    search: search
                )
            } else {
                Section {
                    HStack { Spacer(); ProgressView().scaleEffect(0.8); Spacer() }
                }
            }
            Section {} footer: {
                Text(isReadOnly
                    ? "Built-in roles cannot be edited."
                    : "Select which actions this role can perform.")
            }
            if let error = errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        .searchable(
            text: $search,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search permissions"
        )
        .navigationTitle(mode == .create ? "New Role" : (role?.displayName ?? "Role"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if mode == .create {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            if !isReadOnly {
                ToolbarItem(placement: .confirmationAction) {
                    Button(mode == .create ? "Create" : "Save") {
                        Task { await save() }
                    }
                    .disabled(isSaving || !hasChanges || name.isEmpty || selectedPermissions.isEmpty)
                }
            }
        }
    }

    private func save() async {
        guard let client = manager.client else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        let perms = Array(selectedPermissions)
        let desc = description.isEmpty ? nil : description
        do {
            if let role {
                _ = try await client.roles.update(
                    id: role.id,
                    body: UpdateRole(name: name, description: desc, permissions: perms)
                )
            } else {
                _ = try await client.roles.create(
                    CreateRole(name: name, description: desc, permissions: perms)
                )
            }
            await onUpdate()
            dismiss()
        } catch let ArcaneError.validation(fields) {
            errorMessage = formatValidationFields(fields)
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }
}
