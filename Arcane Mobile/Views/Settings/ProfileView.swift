import SwiftUI
import Arcane

/// Account/profile page mirroring the web's Account view: identity header,
/// editable display name + email, password change, and a disabled language
/// row until localization ships. Follows the app's form conventions —
/// toolbar Save with an in-flight spinner, `FormTextField`/`FormSecureField`
/// rows, toast feedback.
struct ProfileView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager

    @State private var displayName = ""
    @State private var email = ""
    @State private var hasSeededFields = false

    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""

    @State private var isSaving = false
    @State private var errorMessage: String?

    /// Which sign-out flavor is awaiting confirmation.
    private enum PendingSignOut {
        case signOut
        case signOutAndChangeServer
    }
    @State private var pendingSignOut: PendingSignOut?

    private var user: User? { manager.currentUser }
    private var isOIDCUser: Bool { user?.oidcSubjectId?.isEmpty == false }

    private var profileChanged: Bool {
        guard let user, !isOIDCUser else { return false }
        // SSO profiles are owned by the identity provider — name and email
        // are read-only, matching the web UI.
        return displayName.trimmingCharacters(in: .whitespacesAndNewlines) != (user.displayName ?? "")
            || email.trimmingCharacters(in: .whitespacesAndNewlines) != (user.email ?? "")
    }

    private var wantsPasswordChange: Bool {
        !currentPassword.isEmpty || !newPassword.isEmpty || !confirmPassword.isEmpty
    }

    private var passwordValid: Bool {
        !currentPassword.isEmpty && newPassword.count >= 8 && newPassword == confirmPassword
    }

    private var canSave: Bool {
        profileChanged || (wantsPasswordChange && passwordValid)
    }

    var body: some View {
        Form {
            identitySection

            Section {
                if isOIDCUser {
                    LabeledContent("Display Name") {
                        Text(user?.displayName?.isEmpty == false ? user!.displayName! : "—")
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Email") {
                        Text(user?.email?.isEmpty == false ? user!.email! : "—")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    FormTextField(
                        title: "Display Name",
                        placeholder: "Your name",
                        text: $displayName
                    )
                    FormTextField(
                        title: "Email",
                        placeholder: "you@example.com",
                        text: $email,
                        keyboardType: .emailAddress,
                        autocapitalization: .never,
                        autocorrectionDisabled: true
                    )
                }
            } header: {
                Text("Profile")
            } footer: {
                if isOIDCUser {
                    Text("Your profile is managed by your identity provider.")
                }
            }

            if !isOIDCUser {
                passwordSection
            }

            Section {
                LabeledContent("Language") {
                    Text("English")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Language")
            } footer: {
                Text("Language selection is coming in a future update.")
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isSaving {
                    ProgressView().scaleEffect(0.8)
                } else {
                    Button("Save") { Task { await save() } }
                        .disabled(!canSave)
                }
            }
            // Separate glass group so sign-out floats as its own circular
            // button on the far right instead of merging with Save.
            if #available(iOS 26, *) {
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive) {
                        pendingSignOut = .signOut
                    } label: {
                        Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .tint(.red)
                    Button(role: .destructive) {
                        pendingSignOut = .signOutAndChangeServer
                    } label: {
                        Label("Sign Out & Change Server", systemImage: "link")
                    }
                    .tint(.red)
                } label: {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .foregroundStyle(.red)
                }
                .accessibilityLabel("Sign Out options")
            }
        }
        .deleteConfirmation(item: $pendingSignOut) { action in
            switch action {
            case .signOut:
                return DeleteConfirmationConfig(
                    title: "Sign Out",
                    message: "You'll be signed out of this server.",
                    icon: "rectangle.portrait.and.arrow.right",
                    actions: [DeleteConfirmationAction(title: "Sign Out") {
                        Task { await manager.logout() }
                    }]
                )
            case .signOutAndChangeServer:
                return DeleteConfirmationConfig(
                    title: "Change Server",
                    message: "You'll be signed out and asked for a new server URL.",
                    icon: "link",
                    actions: [DeleteConfirmationAction(title: "Sign Out & Change Server") {
                        Task {
                            await manager.logout()
                            manager.authState = .setup
                        }
                    }]
                )
            }
        }
        .onAppear { seedFields() }
    }

    // MARK: - Sections

    private var identitySection: some View {
        Section {
            HStack(spacing: 14) {
                UserAvatarCircle(size: 56, font: .title3.bold())
                VStack(alignment: .leading, spacing: 3) {
                    Text(user?.displayName?.isEmpty == false ? user!.displayName! : (user?.username ?? "—"))
                        .font(.headline)
                    Text("@\(user?.username ?? "—")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        if user?.isAdmin == true {
                            pill("Admin", color: .indigo)
                        }
                        if isOIDCUser {
                            pill("SSO", color: .teal)
                        }
                    }
                }
                Spacer()
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        }
    }

    private var passwordSection: some View {
        Section {
            FormSecureField(
                title: "Current",
                placeholder: "Current password",
                text: $currentPassword,
                textContentType: .password
            )
            FormSecureField(
                title: "New",
                placeholder: "At least 8 characters",
                text: $newPassword,
                textContentType: .newPassword
            )
            FormSecureField(
                title: "Confirm",
                placeholder: "Repeat new password",
                text: $confirmPassword,
                textContentType: .newPassword
            )
        } header: {
            Text("Change Password")
        } footer: {
            if !newPassword.isEmpty && newPassword.count < 8 {
                Text("New password must be at least 8 characters.")
            } else if !confirmPassword.isEmpty && newPassword != confirmPassword {
                Text("Passwords don't match.")
            } else {
                Text("Leave blank to keep your current password.")
            }
        }
    }

    private func pill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color, in: Capsule())
    }

    // MARK: - Actions

    private func seedFields() {
        guard !hasSeededFields, let user else { return }
        hasSeededFields = true
        displayName = user.displayName ?? ""
        email = user.email ?? ""
    }

    /// One Save applies whatever changed: profile fields, password, or both.
    private func save() async {
        guard let client = manager.client, let user else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            var savedSomething = false
            if profileChanged {
                let updated = try await client.users.update(
                    id: user.id,
                    body: UpdateUser(
                        displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                        email: email.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                )
                manager.currentUser = updated
                savedSomething = true
            }
            if wantsPasswordChange && passwordValid {
                try await client.users.changePassword(
                    PasswordChange(currentPassword: currentPassword, newPassword: newPassword)
                )
                currentPassword = ""
                newPassword = ""
                confirmPassword = ""
                savedSomething = true
            }
            if savedSomething {
                showToast(.success("Account updated"))
            }
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }
}
