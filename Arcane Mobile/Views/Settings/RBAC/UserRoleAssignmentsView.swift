import SwiftUI
import Arcane

/// Per-user role assignment editor reached from `UserDetailView`. Shows the
/// user's current assignments grouped by scope (Global first, then per-env),
/// supports swipe-to-remove, and presents `AddRoleAssignmentSheet` for adding
/// new assignments. Only available on v2 servers.
struct UserRoleAssignmentsView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    let user: User

    @State private var assignments: [RoleAssignment] = []
    @State private var availableRoles: [Role] = []
    @State private var availableEnvironments: [Arcane.Environment] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var actionErrorMessage: String?
    @State private var showAddSheet = false

    var body: some View {
        Group {
            if isLoading && assignments.isEmpty {
                ProgressView("Loading assignments…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage, assignments.isEmpty {
                ContentUnavailableView(
                    "Error",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else if assignments.isEmpty {
                ContentUnavailableView(
                    "No Role Assignments",
                    systemImage: "person.crop.circle.badge.questionmark",
                    description: Text("This user has no roles assigned and cannot perform actions.")
                )
            } else {
                listContent
            }
        }
        .navigationTitle("Role Assignments")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showAddSheet = true } label: { Image(systemName: "plus") }
                    .disabled(availableRoles.isEmpty)
            }
        }
        .task { await load() }
        .refreshable { await load(refresh: true) }
        .sheet(isPresented: $showAddSheet) {
            AddRoleAssignmentSheet(
                user: user,
                availableRoles: availableRoles,
                availableEnvironments: availableEnvironments,
                existingAssignments: assignments,
                onSaved: { await load(refresh: true) }
            )
        }
        .alert(
            "Couldn't Update Assignments",
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

    @ViewBuilder
    private var listContent: some View {
        List {
            let global = assignments.filter { $0.environmentId == nil }
            if !global.isEmpty {
                Section("Global") {
                    ForEach(global) { assignment in
                        AssignmentRow(
                            assignment: assignment,
                            role: availableRoles.first(where: { $0.id == assignment.roleId })
                        )
                        .swipeActions(edge: .trailing) {
                            if assignment.sourceKind == .manual {
                                Button(role: .destructive) {
                                    Task { await remove(assignment) }
                                } label: {
                                    DestructiveLabel(text: "Remove")
                                }
                            }
                        }
                    }
                }
            }
            let perEnv = Dictionary(grouping: assignments.filter { $0.environmentId != nil }) { $0.environmentId ?? "" }
            ForEach(perEnv.keys.sorted(), id: \.self) { envID in
                Section(displayScopeLabel(for: envID, environments: availableEnvironments)) {
                    ForEach(perEnv[envID] ?? []) { assignment in
                        AssignmentRow(
                            assignment: assignment,
                            role: availableRoles.first(where: { $0.id == assignment.roleId })
                        )
                        .swipeActions(edge: .trailing) {
                            if assignment.sourceKind == .manual {
                                Button(role: .destructive) {
                                    Task { await remove(assignment) }
                                } label: {
                                    DestructiveLabel(text: "Remove")
                                }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func load(refresh: Bool = false) async {
        guard let client = manager.client else { return }
        if assignments.isEmpty { isLoading = true }
        errorMessage = nil
        defer { isLoading = false }
        do {
            async let assignmentsTask = client.users.getRoleAssignments(userId: user.id)
            async let rolesTask = client.roles.listPaginated(limit: 100)
            async let envsTask = client.environments.list(query: .init(start: 0, limit: 100))
            let (a, r, e) = try await (assignmentsTask, rolesTask, envsTask)
            assignments = a
            availableRoles = r.data
            availableEnvironments = e.data
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func remove(_ assignment: RoleAssignment) async {
        guard let client = manager.client else { return }
        let remainingManual = assignments
            .filter { $0.sourceKind == .manual && $0.id != assignment.id }
            .map { UserAssignmentInput(roleId: $0.roleId, environmentId: $0.environmentId) }
        do {
            let updated = try await client.users.setRoleAssignments(userId: user.id, assignments: remainingManual)
            withAnimation {
                assignments = updated
            }
        } catch let ArcaneError.conflict(message) {
            actionErrorMessage = message ?? "Cannot remove this assignment — at least one global administrator must remain."
        } catch {
            actionErrorMessage = friendlyErrorMessage(error)
        }
    }
}

private struct AssignmentRow: View {
    let assignment: RoleAssignment
    let role: Role?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: role?.systemImage ?? "person.crop.rectangle.fill")
                .foregroundStyle(role?.iconColor ?? .secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(role?.displayName ?? assignment.roleId)
                    .font(.body)
                if assignment.sourceKind == .oidc {
                    Text("From SSO")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if assignment.sourceKind == .oidc {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Add Assignment Sheet

struct AddRoleAssignmentSheet: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.dismiss) private var dismiss

    let user: User
    let availableRoles: [Role]
    let availableEnvironments: [Arcane.Environment]
    let existingAssignments: [RoleAssignment]
    let onSaved: () async -> Void

    @State private var selectedRoleId: String = ""
    @State private var scope: Scope = .global
    @State private var selectedEnvironmentId: String = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    enum Scope: String, CaseIterable, Identifiable {
        case global = "Global"
        case environment = "Specific Environment"
        var id: String { rawValue }
    }

    private var canSave: Bool {
        !selectedRoleId.isEmpty
            && (scope == .global || !selectedEnvironmentId.isEmpty)
            && !isSaving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Role") {
                    Picker("Role", selection: $selectedRoleId) {
                        Text("Choose…").tag("")
                        ForEach(availableRoles) { role in
                            Text(role.displayName).tag(role.id)
                        }
                    }
                }
                Section("Scope") {
                    Picker("Scope", selection: $scope) {
                        ForEach(Scope.allCases) { scope in
                            Text(scope.rawValue).tag(scope)
                        }
                    }
                    if scope == .environment {
                        Picker("Environment", selection: $selectedEnvironmentId) {
                            Text("Choose…").tag("")
                            ForEach(availableEnvironments) { env in
                                Text(env.name ?? "Environment \(env.id)").tag(env.id)
                            }
                        }
                    }
                }
                if let error = errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add Assignment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await save() } }
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
        let envId: String? = scope == .global ? nil : selectedEnvironmentId
        // The PUT endpoint replaces all manual assignments — preserve the
        // existing manual ones and append the new one.
        var inputs = existingAssignments
            .filter { $0.sourceKind == .manual }
            .map { UserAssignmentInput(roleId: $0.roleId, environmentId: $0.environmentId) }
        let new = UserAssignmentInput(roleId: selectedRoleId, environmentId: envId)
        if !inputs.contains(where: { $0.roleId == new.roleId && $0.environmentId == new.environmentId }) {
            inputs.append(new)
        }
        do {
            _ = try await client.users.setRoleAssignments(userId: user.id, assignments: inputs)
            await onSaved()
            dismiss()
        } catch let ArcaneError.validation(fields) {
            errorMessage = formatValidationFields(fields)
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }
}
