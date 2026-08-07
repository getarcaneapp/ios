import Arcane
import ArcanePasskeys
import AuthenticationServices
import SwiftUI

struct PasskeysMFAView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.scenePhase) private var scenePhase

    @State private var passkeys: [PasskeySummary] = []
    @State private var capabilities: PasskeyCapabilities?
    @State private var mfaStatus: MFAStatus?
    @State private var isLoading = false
    @State private var bridgeAvailable = false
    @State private var stepUpGrant: StepUpGrant?
    @State private var passkeyAuthenticator: ArcanePasskeyAuthenticator?
    @State private var queuedAction: ProtectedAction?
    @State private var showsStepUp = false
    @State private var showsAddPrompt = false
    @State private var newPasskeyName = ""
    @State private var renamingPasskey: PasskeySummary?
    @State private var renamedPasskeyName = ""
    @State private var pendingDelete: PasskeySummary?
    @State private var recoveryPresentation: RecoveryCodePresentation?

    private enum ProtectedAction {
        case add(String?)
        case rename(PasskeySummary, String)
        case delete(PasskeySummary)
        case enableMFA
        case disableMFA
        case regenerateRecoveryCodes
    }

    private struct RecoveryCodePresentation: Identifiable {
        let id = UUID()
        let codes: [String]
    }

    var body: some View {
        Form {
            if isLoading && passkeys.isEmpty && mfaStatus == nil {
                Section {
                    HStack {
                        Spacer()
                        ProgressView("Loading security settings…")
                        Spacer()
                    }
                }
            } else {
                mfaSection
                passkeysSection
            }
        }
        .navigationTitle("Passkeys & MFA")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    newPasskeyName = ""
                    showsAddPrompt = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add Passkey")
                .disabled(
                    !bridgeAvailable
                        || capabilities?.canEnrollWithActiveSession == false
                        || isLoading
                )
            }
        }
        .task(id: manager.clientGeneration) {
            cancelPasskeyCeremony()
            clearStepUp()
            await load()
        }
        .task(id: stepUpGrant?.expiresAt) {
            guard let expiresAt = stepUpGrant?.expiresAt else { return }
            let remaining = expiresAt.timeIntervalSinceNow
            if remaining > 0 {
                try? await Task.sleep(for: .seconds(remaining))
            }
            guard !Task.isCancelled, stepUpGrant?.expiresAt == expiresAt else { return }
            clearStepUp()
        }
        .refreshable { await load() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                cancelPasskeyCeremony()
                clearStepUp()
            }
        }
        .onChange(of: manager.clientGeneration) {
            cancelPasskeyCeremony()
            clearStepUp()
        }
        .onDisappear { cancelPasskeyCeremony() }
        .alert("Add Passkey", isPresented: $showsAddPrompt) {
            TextField("Passkey name (optional)", text: $newPasskeyName)
            Button("Cancel", role: .cancel) {}
            Button("Continue") {
                request(
                    .add(newPasskeyName.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty)
                )
            }
        } message: {
            Text("Give this passkey a name you will recognize on this device.")
        }
        .alert(
            "Rename Passkey",
            isPresented: Binding(
                get: { renamingPasskey != nil },
                set: { if !$0 { renamingPasskey = nil } }
            )
        ) {
            TextField("Passkey name", text: $renamedPasskeyName)
            Button("Cancel", role: .cancel) { renamingPasskey = nil }
            Button("Save") {
                guard let passkey = renamingPasskey else { return }
                let name = renamedPasskeyName.trimmingCharacters(in: .whitespacesAndNewlines)
                renamingPasskey = nil
                request(.rename(passkey, name))
            }
            .disabled(renamedPasskeyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .deleteConfirmation(
            item: $pendingDelete,
            title: { _ in "Delete Passkey" },
            message: { passkey in "This removes \(passkey.name) from your Arcane account." },
            icon: "trash",
            confirmTitle: "Delete",
            onConfirm: { passkey in request(.delete(passkey)) }
        )
        .sheet(isPresented: $showsStepUp) {
            StepUpAuthenticationSheet(
                allowsPassword: capabilities?.hasLocalPassword == true,
                allowsPasskey: bridgeAvailable && !passkeys.isEmpty,
                authenticateWithPassword: authenticateStepUpWithPassword,
                authenticateWithPasskey: authenticateStepUpWithPasskey,
                cancel: {
                    queuedAction = nil
                    showsStepUp = false
                }
            )
            .presentationDetents([.medium])
        }
        .sheet(item: $recoveryPresentation) { presentation in
            RecoveryCodesSaveView(codes: presentation.codes) {
                recoveryPresentation = nil
            }
            .interactiveDismissDisabled()
        }
    }

    private var mfaSection: some View {
        Section {
            LabeledContent("Status") {
                Text(mfaStatus?.enabled == true ? "Enabled" : "Disabled")
                    .foregroundStyle(mfaStatus?.enabled == true ? .green : .secondary)
            }
            if let status = mfaStatus, status.enabled {
                LabeledContent("Recovery Codes") {
                    Text(verbatim: String(status.recoveryCodesRemaining))
                        .foregroundStyle(.secondary)
                }
                Button("Generate New Recovery Codes") {
                    request(.regenerateRecoveryCodes)
                }
                Button("Disable Multi-Factor Authentication", role: .destructive) {
                    request(.disableMFA)
                }
            } else {
                Button("Enable Multi-Factor Authentication") {
                    request(.enableMFA)
                }
                .disabled(passkeys.isEmpty)
            }
        } header: {
            Text("Multi-Factor Authentication")
        } footer: {
            if passkeys.isEmpty {
                Text("Add a passkey before enabling multi-factor authentication.")
            } else {
                Text("Arcane requires a fresh password or passkey confirmation for security changes.")
            }
        }
    }

    private var passkeysSection: some View {
        Section {
            if passkeys.isEmpty {
                ContentUnavailableView(
                    "No Passkeys",
                    systemImage: "person.badge.key",
                    description: Text(
                        bridgeAvailable
                            ? "Add a passkey for passwordless sign-in and multi-factor authentication."
                            : "This server does not provide the mobile passkey bridge."
                    )
                )
            } else {
                ForEach(passkeys) { passkey in
                    passkeyRow(passkey)
                }
            }
        } header: {
            Text("Passkeys")
        }
    }

    private func passkeyRow(_ passkey: PasskeySummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(passkey.name)
                        .font(.headline)
                    Text(passkey.rpId)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button {
                        renamedPasskeyName = passkey.name
                        renamingPasskey = passkey
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        pendingDelete = passkey
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(
                        passkeys.count == 1
                            && capabilities?.canDeleteLastPasskey == false
                    )
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Actions for \(passkey.name)")
            }

            HStack(spacing: 10) {
                Label(passkey.createdAt.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                if let lastUsedAt = passkey.lastUsedAt {
                    Label(lastUsedAt.formatted(.relative(presentation: .named)), systemImage: "clock")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if passkey.cloneWarning {
                Label("Authenticator clone warning", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            } else if passkey.backupState {
                Label("Synced passkey", systemImage: "icloud.and.arrow.up")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func load() async {
        guard let client = manager.client else { return }
        let generation = manager.clientGeneration
        isLoading = true
        defer { isLoading = false }

        async let loadedPasskeys = try? client.passkeys.list()
        async let loadedCapabilities = try? client.passkeys.capabilities()
        async let loadedStatus = try? client.passkeys.mfaStatus()
        async let loadedBridge = ArcanePasskeyAuthenticator(client: client).isBridgeAvailable()
        let results = await (loadedPasskeys, loadedCapabilities, loadedStatus, loadedBridge)
        guard generation == manager.clientGeneration else { return }
        passkeys = results.0 ?? []
        capabilities = results.1
        mfaStatus = results.2
        bridgeAvailable = results.3
    }

    private func request(_ action: ProtectedAction) {
        if case .add = action,
           capabilities?.canEnrollWithActiveSession == true,
           capabilities?.requiresStepUp == false {
            Task { await execute(action, using: nil) }
            return
        }
        guard let grant = validStepUpGrant else {
            guard capabilities?.hasLocalPassword == true || (bridgeAvailable && !passkeys.isEmpty) else {
                showToast(.info("No step-up authentication method is available"))
                return
            }
            queuedAction = action
            showsStepUp = true
            return
        }
        Task { await execute(action, using: grant) }
    }

    private var validStepUpGrant: StepUpGrant? {
        guard let stepUpGrant, stepUpGrant.expiresAt > Date() else { return nil }
        return stepUpGrant
    }

    private func authenticateStepUpWithPassword(_ password: String) async -> String? {
        guard let client = manager.client else { return "No server configured" }
        do {
            let grant = try await client.passkeys.passwordStepUp(password: password)
            await finishStepUp(grant)
            return nil
        } catch {
            return friendlyErrorMessage(error)
        }
    }

    @MainActor
    private func authenticateStepUpWithPasskey() async -> String? {
        guard let client = manager.client else { return "No server configured" }
        let authenticator = ArcanePasskeyAuthenticator(client: client)
        passkeyAuthenticator = authenticator
        defer {
            if passkeyAuthenticator === authenticator {
                passkeyAuthenticator = nil
            }
        }
        do {
            let grant = try await authenticator.stepUp(
                presenting: AuthenticationPresentationAnchorProvider.current()
            )
            await finishStepUp(grant)
            return nil
        } catch is CancellationError {
            return nil
        } catch ArcanePasskeyAuthenticator.CeremonyError.cancelled {
            return nil
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return nil
        } catch {
            return friendlyErrorMessage(error)
        }
    }

    private func finishStepUp(_ grant: StepUpGrant) async {
        stepUpGrant = grant
        showsStepUp = false
        guard let action = queuedAction else { return }
        queuedAction = nil
        await execute(action, using: grant)
    }

    private func execute(_ action: ProtectedAction, using grant: StepUpGrant?) async {
        guard let client = manager.client else { return }
        if let grant, grant.expiresAt <= Date() {
            clearStepUp()
            request(action)
            return
        }
        if grant == nil {
            guard case .add = action,
                  capabilities?.canEnrollWithActiveSession == true,
                  capabilities?.requiresStepUp == false else {
                request(action)
                return
            }
        }
        let generation = manager.clientGeneration
        isLoading = true
        defer { isLoading = false }

        do {
            switch action {
            case .add(let name):
                guard bridgeAvailable else {
                    showToast(.info("This server does not provide the mobile passkey bridge"))
                    return
                }
                let authenticator = ArcanePasskeyAuthenticator(client: client)
                passkeyAuthenticator = authenticator
                defer {
                    if passkeyAuthenticator === authenticator {
                        passkeyAuthenticator = nil
                    }
                }
                _ = try await authenticator.register(
                    name: name,
                    stepUpToken: grant?.token,
                    presenting: AuthenticationPresentationAnchorProvider.current()
                )
                showToast(.success("Passkey added"))
            case .rename(let passkey, let name):
                guard let stepUpToken = grant?.token else { return }
                _ = try await client.passkeys.rename(
                    id: passkey.id,
                    name: name,
                    stepUpToken: stepUpToken
                )
                showToast(.success("Passkey renamed"))
            case .delete(let passkey):
                guard let stepUpToken = grant?.token else { return }
                try await client.passkeys.delete(id: passkey.id, stepUpToken: stepUpToken)
                showToast(.success("Passkey deleted"))
            case .enableMFA:
                guard let stepUpToken = grant?.token else { return }
                let response = try await client.passkeys.enableMFA(stepUpToken: stepUpToken)
                recoveryPresentation = RecoveryCodePresentation(codes: response.codes)
            case .disableMFA:
                guard let stepUpToken = grant?.token else { return }
                try await client.passkeys.disableMFA(stepUpToken: stepUpToken)
                showToast(.success("Multi-factor authentication disabled"))
            case .regenerateRecoveryCodes:
                guard let stepUpToken = grant?.token else { return }
                let response = try await client.passkeys.regenerateRecoveryCodes(
                    stepUpToken: stepUpToken
                )
                recoveryPresentation = RecoveryCodePresentation(codes: response.codes)
            }
            guard generation == manager.clientGeneration else { return }
            await load()
        } catch is CancellationError {
            return
        } catch ArcanePasskeyAuthenticator.CeremonyError.cancelled {
            return
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return
        } catch {
            guard generation == manager.clientGeneration else { return }
            showToast(.error(friendlyErrorMessage(error)))
        }
    }

    private func clearStepUp() {
        stepUpGrant = nil
        queuedAction = nil
        showsStepUp = false
    }

    private func cancelPasskeyCeremony() {
        passkeyAuthenticator?.cancel()
        passkeyAuthenticator = nil
    }
}

private struct StepUpAuthenticationSheet: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss

    let allowsPassword: Bool
    let allowsPasskey: Bool
    let authenticateWithPassword: (String) async -> String?
    let authenticateWithPasskey: () async -> String?
    let cancel: () -> Void

    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Confirm your identity before changing account security settings.")
                        .foregroundStyle(.secondary)
                }
                if allowsPassword {
                    Section("Password") {
                        FormSecureField(
                            title: "Password",
                            placeholder: "Current password",
                            text: $password,
                            textContentType: .password
                        )
                        Button("Continue with Password") {
                            Task { await usePassword() }
                        }
                        .disabled(password.isEmpty || isLoading)
                    }
                }
                if allowsPasskey {
                    Section {
                        Button {
                            Task { await usePasskey() }
                        } label: {
                            Label("Continue with Passkey", systemImage: "person.badge.key.fill")
                        }
                        .disabled(isLoading)
                    }
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Confirm Identity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        cancel()
                        dismiss()
                    }
                }
                if isLoading {
                    ToolbarItem(placement: .confirmationAction) {
                        ProgressView()
                    }
                }
            }
        }
    }

    private func usePassword() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        errorMessage = await authenticateWithPassword(password)
    }

    private func usePasskey() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        errorMessage = await authenticateWithPasskey()
    }
}

private struct RecoveryCodesSaveView: View {
    let codes: [String]
    let confirmSaved: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Save these codes somewhere secure. They will not be shown again.")
                        .foregroundStyle(.secondary)
                }
                Section("Recovery Codes") {
                    ForEach(codes, id: \.self) { code in
                        Text(code)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                Section {
                    Button {
                        UIPasteboard.general.string = codes.joined(separator: "\n")
                        showToast(.copied("Recovery codes copied"))
                    } label: {
                        Label("Copy All Codes", systemImage: "doc.on.doc")
                    }
                }
            }
            .navigationTitle("Save Recovery Codes")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                Button("I've Saved These Codes") {
                    confirmSaved()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .padding()
                .background(.bar)
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
