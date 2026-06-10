import SwiftUI
import Arcane

struct UserDetailView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let user: User
    let onUpdate: () async -> Void

    @State private var email: String
    @State private var displayName: String
    @State private var isAdmin: Bool
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(user: User, onUpdate: @escaping () async -> Void) {
        self.user = user
        self.onUpdate = onUpdate
        _email = State(initialValue: user.email ?? "")
        _displayName = State(initialValue: user.displayName ?? "")
        _isAdmin = State(initialValue: user.isAdmin)
    }

    private var hasChanges: Bool {
        email != (user.email ?? "")
            || displayName != (user.displayName ?? "")
            || (!supportsV2 && isAdmin != user.isAdmin)
    }

    private var supportsV2: Bool {
        manager.serverCapabilities?.supportsRoleManagement == true
    }

    var body: some View {
        Form {
            Section("Identity") {
                FormValueRow(title: "Username", value: user.username)
                FormTextField(
                    title: "Email",
                    placeholder: "Optional",
                    text: $email,
                    keyboardType: .emailAddress,
                    autocapitalization: .never,
                    autocorrectionDisabled: true
                )
                FormTextField(
                    title: "Display Name",
                    placeholder: "Optional",
                    text: $displayName,
                    autocapitalization: .words
                )
            }
            accessSection
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

    @ViewBuilder
    private var accessSection: some View {
        Section("Access") {
            if supportsV2 {
                NavigationLink(destination: UserRoleAssignmentsView(user: user)) {
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.rectangle.stack")
                            .foregroundStyle(.indigo)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Role Assignments")
                            Text("Manage global and per-environment roles")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                }
            } else {
                Toggle("Administrator", isOn: $isAdmin)
            }
        }
    }

    private func saveUser() async {
        guard let client = manager.client else { return }
        isSaving = true; errorMessage = nil
        defer { isSaving = false }
        let supportsRBAC = manager.serverCapabilities?.supportsRoleManagement == true
        do {
            let body = UpdateUserRequest(
                displayName: displayName.isEmpty ? nil : displayName,
                email: email.isEmpty ? nil : email,
                roles: supportsRBAC ? nil : (isAdmin ? ["admin"] : [])
            )
            _ = try await client.users.update(id: user.id, body: body)
            await onUpdate()
            dismiss()
        } catch { errorMessage = friendlyErrorMessage(error) }
    }
}

