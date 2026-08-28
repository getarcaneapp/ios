import SwiftUI
import Arcane

struct RolesView: View {
    private static let pageSize = 50

    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @State private var roles: [Role] = []
    @State private var manifest: PermissionsManifest?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var actionErrorMessage: String?
    @State private var showCreateSheet = false
    @State private var pendingDeleteRole: Role?
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var pagination = ProgressivePaginationState()
    @State private var isLoadingMore = false
    @State private var loadMoreError: String?

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
                        Section {
                            ForEach(builtIns) { role in
                                NavigationLink(destination: RoleDetailView(role: role, manifest: manifest, mode: .readOnly, onUpdate: { await load(refresh: true) })) {
                                    RoleRow(role: role)
                                }
                            }
                        } header: {
                            ResourceCountSectionHeader(
                                "Built-in",
                                loadedCount: roles.count,
                                totalCount: pagination.totalItems,
                                hasMore: pagination.hasMore
                            )
                        }
                    }
                    if !customs.isEmpty {
                        Section {
                            ForEach(customs) { role in
                                NavigationLink(destination: RoleDetailView(role: role, manifest: manifest, mode: .edit, onUpdate: { await load(refresh: true) })) {
                                    RoleRow(role: role)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button {
                                        pendingDeleteRole = role
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    .tint(.red)
                                }
                            }
                        } header: {
                            if builtIns.isEmpty {
                                ResourceCountSectionHeader(
                                    "Custom",
                                    loadedCount: roles.count,
                                    totalCount: pagination.totalItems,
                                    hasMore: pagination.hasMore
                                )
                            } else {
                                Text("Custom")
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
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Roles")
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search roles"
        )
        .debounce(searchText, for: .milliseconds(200), into: $debouncedSearchText)
        .onChange(of: debouncedSearchText) {
            Task { await load(refresh: true) }
        }
        .toolbar {
            if manager.canAccess(.oidcRoleMappings) {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink {
                        OIDCRoleMappingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Manage OIDC Role Mappings")
                }
            }
            if #available(iOS 26, *),
               rbacAvailable,
               manager.permissions.canManageRoles,
               manager.canAccess(.oidcRoleMappings) {
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
            }
            if rbacAvailable && manager.permissions.canManageRoles {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showCreateSheet = true } label: { Image(systemName: "plus") }.accessibilityLabel("Create Role")
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
        let generation = pagination.reset()
        isLoadingMore = false
        if roles.isEmpty { isLoading = true }
        errorMessage = nil
        loadMoreError = nil
        defer {
            if pagination.accepts(generation) {
                isLoading = false
            }
        }
        do {
            async let rolesPage = client.roles.listPaginated(
                search: debouncedSearchText.isEmpty ? nil : debouncedSearchText,
                start: 0,
                limit: Self.pageSize
            )
            async let manifestResp = client.roles.availablePermissions()
            let (page, m) = try await (rolesPage, manifestResp)
            manifest = m
            applyPage(page, reset: true, requestedStart: 0, generation: generation)
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
            let response = try await client.roles.listPaginated(
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
        _ response: PaginatedResponse<Role>,
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
        roles = PaginationLoader.merge(current: roles, incoming: response.data, reset: reset)
        loadMoreError = nil
    }

    private func deleteRole(_ role: Role) async {
        guard let client = manager.client else { return }
        do {
            try await client.roles.delete(id: role.id)
            withAnimation {
                roles.removeAll { $0.id == role.id }
            }
            await load(refresh: true)
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
                    Text(verbatim: "\(role.permissions.count) permissions")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if role.assignedUserCount > 0 {
                        Text("·")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(verbatim: "\(role.assignedUserCount) assigned")
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
        guard let role else {
            return !name.isEmpty || !description.isEmpty || !selectedPermissions.isEmpty
        }
        return name != role.name
            || description != (role.description ?? "")
            || selectedPermissions != Set(role.permissions)
    }

    private var canSave: Bool {
        !name.isEmpty && !selectedPermissions.isEmpty
    }

    var body: some View {
        Form {
            Section {
                if isReadOnly {
                    FormValueRow(title: "Name", value: name)
                    if !description.isEmpty {
                        FormValueRow(title: "Description", value: description)
                    }
                } else {
                    FormTextField(
                        title: "Name",
                        placeholder: "Deploy Operator",
                        text: $name
                    )
                    FormTextField(
                        title: "Description",
                        placeholder: "Optional",
                        text: $description,
                        axis: .vertical,
                        lineLimit: 2...4
                    )
                }
            } header: {
                Text("Role Info")
            } footer: {
                if !isReadOnly {
                    Text("Use a short name that explains who this role is for.")
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
        .settingsSaveBar(
            isPresented: !isReadOnly,
            hasChanges: hasChanges,
            isSaving: isSaving,
            canSave: canSave,
            saveAccessibilityLabel: mode == .create ? "Create" : "Save",
            onSave: { Task { await save() } },
            onRevert: revertChanges
        )
        .toolbar {
            if mode == .create {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func revertChanges() {
        name = role?.name ?? ""
        description = role?.description ?? ""
        selectedPermissions = Set(role?.permissions ?? [])
        errorMessage = nil
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
