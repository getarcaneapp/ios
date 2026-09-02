import SwiftUI

struct ConnectionProfilesView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(ConnectionProfileStore.self) private var profileStore
    @SwiftUI.Environment(\.dismiss) private var dismiss

    var suggestedServerURL: String = ""
    var onSelect: ((ConnectionProfile) -> Void)?

    @State private var editorTarget: EditorTarget?
    @State private var pendingConfirmation: PendingConfirmation?

    private struct EditorTarget: Identifiable {
        let profile: ConnectionProfile?
        let suggestedServerURL: String

        var id: String { profile?.id.uuidString ?? "new" }
    }

    private enum PendingConfirmation {
        case delete(ConnectionProfile)
        case switchServer(ConnectionProfile)
    }

    private var isSelecting: Bool { onSelect != nil }

    private var canSaveCurrentServer: Bool {
        !manager.serverURL.isEmpty
            && !manager.isDemoActive
            && profileStore.profile(matching: manager.serverURL) == nil
    }

    var body: some View {
        List {
            if canSaveCurrentServer {
                Section {
                    Button(action: saveCurrentServer) {
                        Label("Save Current Server", systemImage: "plus.circle.fill")
                    }
                } footer: {
                    Text("Adds the connected server as a profile. Edit it to include a saved sign-in.")
                }
            }

            Section {
                if profileStore.profiles.isEmpty {
                    ContentUnavailableView(
                        "No Connection Profiles",
                        systemImage: "server.rack",
                        description: Text("Add a server once, then choose it quickly on any device using your iCloud account.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 220)
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(profileStore.profiles) { profile in
                        profileRow(profile)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    pendingConfirmation = .delete(profile)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .tint(.red)

                                Button {
                                    editorTarget = EditorTarget(
                                        profile: profile,
                                        suggestedServerURL: profile.serverURL
                                    )
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(.blue)
                            }
                            .contextMenu {
                                Button {
                                    editorTarget = EditorTarget(
                                        profile: profile,
                                        suggestedServerURL: profile.serverURL
                                    )
                                } label: {
                                    Label("Edit Profile", systemImage: "pencil")
                                }
                                Button(role: .destructive) {
                                    pendingConfirmation = .delete(profile)
                                } label: {
                                    DestructiveLabel(text: "Delete Profile")
                                }
                                .tint(.red)
                            }
                    }
                }
            } header: {
                Text("Saved Profiles")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(profileStore.syncState.description)
                    Text("Profiles can include a password sign-in. Profiles and sign-ins sync through iCloud Keychain; sessions stay on each device.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Connection Profiles")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isSelecting {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editorTarget = EditorTarget(
                        profile: nil,
                        suggestedServerURL: editorSuggestion
                    )
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add Connection Profile")
            }
        }
        .sheet(item: $editorTarget) { target in
            NavigationStack {
                ConnectionProfileEditorView(
                    profile: target.profile,
                    suggestedServerURL: target.suggestedServerURL
                )
            }
            .toastHost(reservesTabBarSpace: false)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .deleteConfirmation(item: $pendingConfirmation) { confirmation in
            switch confirmation {
            case .delete(let profile):
                return DeleteConfirmationConfig(
                    title: "Delete \(profile.name)?",
                    message: deleteMessage(for: profile),
                    icon: "trash",
                    actions: [DeleteConfirmationAction(title: "Delete Profile") {
                        do {
                            try profileStore.delete(profile)
                            showToast(.success("Connection profile deleted"))
                        } catch {
                            showToast(.error(error.localizedDescription))
                        }
                    }]
                )
            case .switchServer(let profile):
                return DeleteConfirmationConfig(
                    title: "Switch to \(profile.name)?",
                    message: "You'll be signed out of the current server. Its saved profile will remain available.",
                    icon: "arrow.left.arrow.right",
                    actions: [DeleteConfirmationAction(title: "Switch Server") {
                        connect(to: profile)
                    }]
                )
            }
        }
    }

    private var editorSuggestion: String {
        if !suggestedServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return suggestedServerURL
        }
        return manager.isDemoActive ? "" : manager.serverURL
    }

    private func profileRow(_ profile: ConnectionProfile) -> some View {
        Button {
            select(profile)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isCurrent(profile) ? "checkmark.circle.fill" : "server.rack")
                    .foregroundStyle(isCurrent(profile) ? Color.green : Color.teal)
                    .frame(width: 28)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.name)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(profile.serverURL)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                if profileStore.hasSyncedCredential(for: profile) {
                    Image(systemName: "icloud.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.blue)
                        .accessibilityLabel("Sign-in synced with iCloud")
                }

                if isCurrent(profile) {
                    Text("Current")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(profile.name), \(profile.serverURL)")
        .accessibilityValue(profileAccessibilityValue(profile))
        .accessibilityHint(isSelecting ? "Connects to this server" : "Switches to this server")
    }

    private func select(_ profile: ConnectionProfile) {
        if let onSelect {
            onSelect(profile)
            dismiss()
        } else if !isCurrent(profile) {
            pendingConfirmation = .switchServer(profile)
        }
    }

    private func connect(to profile: ConnectionProfile) {
        manager.configure(serverURL: profile.serverURL)
        if manager.errorMessage == nil {
            showToast(.info("Switched to \(profile.name)"))
        }
    }

    private func saveCurrentServer() {
        do {
            try profileStore.saveConnectedServer(manager.serverURL)
            showToast(.success("Connection profile saved"))
        } catch {
            showToast(.error(error.localizedDescription))
        }
    }

    private func isCurrent(_ profile: ConnectionProfile) -> Bool {
        profileStore.profile(matching: manager.serverURL)?.id == profile.id
    }

    private func deleteMessage(for profile: ConnectionProfile) -> String {
        let item = profileStore.hasSyncedCredential(for: profile)
            ? "profile and its synced sign-in"
            : "saved profile"
        if isCurrent(profile) {
            return "This removes the \(item) from iCloud but does not disconnect the current server."
        }
        return "This removes the \(item) from iCloud on your devices."
    }

    private func profileAccessibilityValue(_ profile: ConnectionProfile) -> String {
        var values: [String] = []
        if isCurrent(profile) {
            values.append("Current server")
        }
        if profileStore.hasSyncedCredential(for: profile) {
            values.append("Sign-in synced with iCloud")
        }
        return values.joined(separator: ", ")
    }
}

private struct ConnectionProfileEditorView: View {
    @SwiftUI.Environment(ConnectionProfileStore.self) private var profileStore
    @SwiftUI.Environment(\.dismiss) private var dismiss

    let profile: ConnectionProfile?

    @State private var name: String
    @State private var serverURL: String
    @State private var username = ""
    @State private var password = ""
    @State private var credentialLoadState: CredentialLoadState
    @State private var hasExistingCredential = false
    @State private var signInNotice: String?
    @State private var validationMessage: String?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case name
        case serverURL
        case username
        case password
    }

    private enum CredentialLoadState: Equatable {
        case loading
        case ready
        case failed
    }

    init(
        profile: ConnectionProfile?,
        suggestedServerURL: String
    ) {
        self.profile = profile
        _name = State(initialValue: profile?.name ?? "")
        _serverURL = State(initialValue: profile?.serverURL ?? suggestedServerURL)
        _credentialLoadState = State(initialValue: profile == nil ? .ready : .loading)
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name, prompt: Text("Home Server"))
                    .focused($focusedField, equals: .name)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .serverURL }

                TextField("Server URL", text: $serverURL, prompt: Text("arcane.example.com"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .focused($focusedField, equals: .serverURL)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .username }
            } header: {
                Text("Profile")
            } footer: {
                Text("HTTP or HTTPS only. URL credentials, query parameters, and fragments are removed before iCloud sync.")
            }

            Section {
                switch credentialLoadState {
                case .loading:
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading Saved Sign-In")
                            .foregroundStyle(.secondary)
                    }
                case .failed:
                    Button("Retry Loading Sign-In", action: loadCredential)
                case .ready:
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.username)
                        .focused($focusedField, equals: .username)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .password }

                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .focused($focusedField, equals: .password)
                        .submitLabel(.done)
                        .onSubmit(save)

                    if hasExistingCredential {
                        Button("Remove Saved Sign-In", role: .destructive) {
                            username = ""
                            password = ""
                            hasExistingCredential = false
                            signInNotice = "The saved sign-in will be removed when you save."
                        }
                    }
                }
            } header: {
                Text("Sign-In (Optional)")
            } footer: {
                Text(signInNotice ?? "A saved sign-in travels with this profile through iCloud Keychain.")
            }

            if let validationMessage {
                Section {
                    Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(profile == nil ? "New Profile" : "Edit Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .disabled(
                        serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || credentialLoadState != .ready
                    )
            }
        }
        .onChange(of: name) { _, _ in validationMessage = nil }
        .onChange(of: serverURL) { _, newValue in
            validationMessage = nil
            clearCredentialIfServerChanged(to: newValue)
        }
        .onChange(of: username) { _, _ in validationMessage = nil }
        .onChange(of: password) { _, _ in validationMessage = nil }
        .task { loadCredential() }
        .onAppear {
            focusedField = profile == nil && serverURL.isEmpty ? .serverURL : .name
        }
    }

    private func save() {
        guard credentialLoadState == .ready else { return }
        do {
            let credential = try SyncedConnectionCredential.optional(
                username: username,
                password: password
            )
            try profileStore.saveConnectionProfile(
                profile,
                name: name,
                serverURL: serverURL,
                credential: credential
            )
            showToast(.success(profile == nil ? "Connection profile added" : "Connection profile updated"))
            dismiss()
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    private func loadCredential() {
        guard let profile else {
            credentialLoadState = .ready
            return
        }

        credentialLoadState = .loading
        validationMessage = nil
        do {
            let credential = try profileStore.syncedCredential(for: profile)
            let draftURL = try? ConnectionProfileSync.normalizedServerURL(serverURL)
            if let credential, draftURL == profile.serverURL {
                username = credential.username
                password = credential.password
                hasExistingCredential = true
            } else if credential != nil {
                signInNotice = "Re-enter the sign-in after changing the server address."
            }
            credentialLoadState = .ready
        } catch {
            credentialLoadState = .failed
            validationMessage = error.localizedDescription
        }
    }

    private func clearCredentialIfServerChanged(to newValue: String) {
        guard let profile,
              hasExistingCredential,
              let normalized = try? ConnectionProfileSync.normalizedServerURL(newValue),
              normalized != profile.serverURL else { return }

        username = ""
        password = ""
        hasExistingCredential = false
        signInNotice = "Re-enter the sign-in after changing the server address."
    }
}
