import SwiftUI
import Arcane

struct OIDCRoleMappingsView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @State private var mappings: [OidcRoleMapping] = []
    @State private var availableRoles: [Role] = []
    @State private var availableEnvironments: [Arcane.Environment] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var actionErrorMessage: String?
    @State private var showCreateSheet = false
    @State private var editingMapping: OidcRoleMapping?
    @State private var pendingDeleteMapping: OidcRoleMapping?

    private var rbacAvailable: Bool {
        manager.serverCapabilities?.supportsRoleManagement == true
    }

    var body: some View {
        Group {
            if !rbacAvailable {
                ContentUnavailableView(
                    "OIDC Role Mappings Not Available",
                    systemImage: "lock.slash",
                    description: Text("Requires Arcane v2 or newer.")
                )
            } else if !manager.permissions.canManageOIDCMappings {
                ContentUnavailableView(
                    "Admin Required",
                    systemImage: "lock.fill",
                    description: Text("Only global administrators can manage OIDC role mappings.")
                )
            } else if isLoading && mappings.isEmpty {
                ProgressView("Loading mappings…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage, mappings.isEmpty {
                ContentUnavailableView(
                    "Error",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else if mappings.isEmpty {
                ContentUnavailableView(
                    "No Mappings",
                    systemImage: "person.badge.key",
                    description: Text("Map an SSO claim value to a role to grant it on login.")
                )
            } else {
                List {
                    ForEach(mappings) { mapping in
                        Button {
                            if mapping.sourceKind == .manual {
                                editingMapping = mapping
                            }
                        } label: {
                            MappingRow(
                                mapping: mapping,
                                role: availableRoles.first(where: { $0.id == mapping.roleId }),
                                environmentLabel: displayScopeLabel(for: mapping.environmentId, environments: availableEnvironments)
                            )
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if mapping.sourceKind == .manual {
                                Button {
                                    pendingDeleteMapping = mapping
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
        .navigationTitle("OIDC Role Mappings")
        .toolbar {
            if rbacAvailable && manager.permissions.canManageOIDCMappings {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showCreateSheet = true } label: { Image(systemName: "plus") }.accessibilityLabel("Add Role Mapping")
                }
            }
        }
        .task { await load() }
        .refreshable { await load(refresh: true) }
        .sheet(isPresented: $showCreateSheet) {
            OIDCMappingFormSheet(
                editing: nil,
                availableRoles: availableRoles,
                availableEnvironments: availableEnvironments,
                onSaved: { await load(refresh: true) }
            )
        }
        .sheet(item: $editingMapping) { mapping in
            OIDCMappingFormSheet(
                editing: mapping,
                availableRoles: availableRoles,
                availableEnvironments: availableEnvironments,
                onSaved: { await load(refresh: true) }
            )
        }
        .alert(
            "Couldn't Delete Mapping",
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
            item: $pendingDeleteMapping,
            title: { _ in "Delete Mapping" },
            message: { "Delete the mapping for “\($0.claimValue)”? Users won't receive this role on their next login." },
            icon: "trash",
            confirmTitle: "Delete"
        ) { mapping in
            Task { await delete(mapping) }
        }
    }

    private func load(refresh: Bool = false) async {
        guard rbacAvailable, let client = manager.client else { return }
        if mappings.isEmpty { isLoading = true }
        errorMessage = nil
        defer { isLoading = false }
        do {
            async let mappingsTask = client.oidcRoleMappings.list()
            async let rolesTask = client.roles.listPaginated(limit: 100)
            async let envsTask = client.environments.list(query: .init(start: 0, limit: 100))
            let (m, r, e) = try await (mappingsTask, rolesTask, envsTask)
            mappings = m
            availableRoles = r.data
            availableEnvironments = e.data
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func delete(_ mapping: OidcRoleMapping) async {
        guard let client = manager.client else { return }
        do {
            try await client.oidcRoleMappings.delete(id: mapping.id)
            withAnimation { mappings.removeAll { $0.id == mapping.id } }
        } catch {
            actionErrorMessage = friendlyErrorMessage(error)
        }
    }
}

private struct MappingRow: View {
    let mapping: OidcRoleMapping
    let role: Role?
    let environmentLabel: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: role?.systemImage ?? "person.badge.key")
                .foregroundStyle(role?.iconColor ?? .indigo)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(mapping.claimValue)
                        .font(.body.monospaced())
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(role?.displayName ?? mapping.roleId)
                        .font(.body.weight(.semibold))
                }
                Text(environmentLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if mapping.sourceKind == .env {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Create / Edit Sheet

private struct OIDCMappingFormSheet: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.dismiss) private var dismiss

    let editing: OidcRoleMapping?
    let availableRoles: [Role]
    let availableEnvironments: [Arcane.Environment]
    let onSaved: () async -> Void

    @State private var claimValue: String
    @State private var roleId: String
    @State private var scope: Scope
    @State private var environmentId: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    enum Scope: String, CaseIterable, Identifiable {
        case global = "Global"
        case environment = "Specific Environment"
        var id: String { rawValue }
    }

    init(
        editing: OidcRoleMapping?,
        availableRoles: [Role],
        availableEnvironments: [Arcane.Environment],
        onSaved: @escaping () async -> Void
    ) {
        self.editing = editing
        self.availableRoles = availableRoles
        self.availableEnvironments = availableEnvironments
        self.onSaved = onSaved
        _claimValue = State(initialValue: editing?.claimValue ?? "")
        _roleId = State(initialValue: editing?.roleId ?? "")
        _scope = State(initialValue: editing?.environmentId == nil ? .global : .environment)
        _environmentId = State(initialValue: editing?.environmentId ?? "")
    }

    private var canSave: Bool {
        !claimValue.isEmpty
            && !roleId.isEmpty
            && (scope == .global || !environmentId.isEmpty)
            && !isSaving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Claim Value") {
                    FormTextField(
                        title: "Claim Value",
                        placeholder: "docker-admins",
                        text: $claimValue,
                        autocapitalization: .never,
                        autocorrectionDisabled: true,
                        helper: "Enter the exact value from the configured OIDC claim."
                    )
                }
                Section("Role") {
                    Picker("Role", selection: $roleId) {
                        Text("Choose…").tag("")
                        ForEach(availableRoles) { role in
                            Text(role.displayName).tag(role.id)
                        }
                    }
                }
                Section {
                    Picker("Scope", selection: $scope) {
                        ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if scope == .environment {
                        Picker("Environment", selection: $environmentId) {
                            Text("Choose…").tag("")
                            ForEach(availableEnvironments) { env in
                                Text(env.name ?? "Environment \(env.id)").tag(env.id)
                            }
                        }
                    }
                } header: {
                    Text("Scope")
                } footer: {
                    if scope == .global {
                        Text("Global mappings apply across every environment.")
                    } else {
                        Text("Environment mappings only apply inside the selected environment.")
                    }
                }
                if let error = errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(editing == nil ? "New Mapping" : "Edit Mapping")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(!canSave)
                }
            }
        }
    }

    private func save() async {
        guard let client = manager.client else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        let envId: String? = scope == .global ? nil : environmentId
        do {
            if let editing {
                _ = try await client.oidcRoleMappings.update(
                    id: editing.id,
                    body: UpdateOidcRoleMapping(claimValue: claimValue, roleId: roleId, environmentId: envId)
                )
            } else {
                _ = try await client.oidcRoleMappings.create(
                    CreateOidcRoleMapping(claimValue: claimValue, roleId: roleId, environmentId: envId)
                )
            }
            await onSaved()
            dismiss()
        } catch let ArcaneError.validation(fields) {
            errorMessage = formatValidationFields(fields)
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }
}
