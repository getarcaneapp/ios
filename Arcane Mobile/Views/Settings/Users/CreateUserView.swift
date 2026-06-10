import SwiftUI
import Arcane

struct CreateUserView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let onSuccess: () async -> Void

    @State private var username = ""
    @State private var password = ""
    @State private var email = ""
    @State private var isAdmin = false
    @State private var availableRoles: [Role] = []
    @State private var selectedRoleId = ""
    @State private var isLoadingRoles = false
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var supportsRoleManagement: Bool {
        manager.serverCapabilities?.supportsRoleManagement == true
    }

    private var canCreate: Bool {
        !username.isEmpty
            && !password.isEmpty
            && !isLoading
            && (!supportsRoleManagement || !selectedRoleId.isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Credentials") {
                    FormTextField(
                        title: "Username",
                        placeholder: "Required",
                        text: $username,
                        autocapitalization: .never,
                        autocorrectionDisabled: true
                    )
                    FormSecureField(title: "Password", placeholder: "Required", text: $password)
                }
                Section("Profile") {
                    FormTextField(
                        title: "Email",
                        placeholder: "Optional",
                        text: $email,
                        keyboardType: .emailAddress,
                        autocapitalization: .never,
                        autocorrectionDisabled: true
                    )
                }
                rolesSection
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
                        .disabled(!canCreate)
                }
            }
            .task { await loadRolesIfNeeded() }
        }
    }

    @ViewBuilder
    private var rolesSection: some View {
        Section {
            if supportsRoleManagement {
                if isLoadingRoles && availableRoles.isEmpty {
                    ProgressView("Loading roles…")
                } else {
                    Picker("Role", selection: $selectedRoleId) {
                        Text("Choose…").tag("")
                        ForEach(availableRoles) { role in
                            Text(role.displayName).tag(role.id)
                        }
                    }
                }
            } else {
                Toggle("Administrator", isOn: $isAdmin)
            }
        } header: {
            Text("Roles")
        } footer: {
            if supportsRoleManagement {
                Text(
                    "The selected role is assigned globally. "
                        + "Per-environment assignments can be edited after creation."
                )
            }
        }
    }

    private func createUser() async {
        guard let client = manager.client else { return }
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        let supportsRBAC = supportsRoleManagement
        do {
            let body = CreateUserRequest(
                username: username,
                password: password,
                displayName: nil,
                email: email.isEmpty ? nil : email,
                roles: supportsRBAC ? nil : (isAdmin ? ["admin"] : ["user"])
            )
            let created = try await client.users.create(body)
            if supportsRBAC {
                do {
                    _ = try await client.users.setRoleAssignments(
                        userId: created.id,
                        assignments: [UserAssignmentInput(roleId: selectedRoleId)]
                    )
                } catch {
                    errorMessage = "User created, but the role could not be assigned: \(friendlyErrorMessage(error))"
                    await onSuccess()
                    return
                }
            }
            await onSuccess(); dismiss()
        } catch { errorMessage = friendlyErrorMessage(error) }
    }

    private func loadRolesIfNeeded() async {
        guard supportsRoleManagement, availableRoles.isEmpty, let client = manager.client else { return }
        isLoadingRoles = true
        defer { isLoadingRoles = false }
        do {
            let page = try await client.roles.listPaginated(limit: 100)
            availableRoles = page.data
            if selectedRoleId.isEmpty {
                selectedRoleId = page.data.first(where: { $0.id == Role.BuiltIn.viewer })?.id
                    ?? page.data.first?.id
                    ?? ""
            }
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }
}

// MARK: - API Keys View

