import SwiftUI
import Arcane
import AuthenticationServices

enum LoginMode {
    case setup   // First-time server URL entry
    case login   // Credentials entry
}

struct LoginView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @AppStorage("accentColorHex") private var accentColorHex: String = ""
    var mode: LoginMode

    @State private var serverURL: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var recoveryCode: String = ""
    @State private var showSetup: Bool = false

    @State private var showsPasswordForm: Bool = false
    @State private var logoAppeared: Bool = false
    @FocusState private var focusedField: Field?
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Field: Hashable {
        case serverURL, username, password, recoveryCode
    }

    private var isSetupMode: Bool { mode == .setup || showSetup }

    private var oidcRefreshTaskID: String {
        "\(isSetupMode)-\(manager.serverURL)-\(manager.clientGeneration)"
    }

    // When OIDC is enabled, the password form is hidden behind a disclosure
    // so the provider button is the primary action. The user can still reveal
    // it to sign in locally (e.g. admin fallback).
    private var shouldShowPasswordFields: Bool {
        !manager.isOIDCAvailable || showsPasswordForm
    }

    // The user's chosen accent color from Settings, falling back to the
    // system accent so unconfigured users still get a reasonable tint.
    private var brandColor: Color {
        if let custom = Color(hex: accentColorHex) {
            return custom
        }
        return .accentColor
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer(minLength: 0)

                headerSection

                if !manager.isStartingDemo {
                    VStack(spacing: 12) {
                        formCard
                            .transition(.opacity.combined(with: .move(edge: .top)))

                        if let error = manager.errorMessage {
                            ErrorBanner(message: error)
                        }

                        if let info = manager.demoExpiredMessage {
                            infoBanner(info)
                        }

                        actions
                    }
                    .padding(.top, 28)
                    .transition(.opacity)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
            .containerRelativeFrame(.vertical, alignment: .center) { length, _ in length }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .top, spacing: 0) {
            if manager.pendingMFAChallenge == nil {
                demoBanner
            }
        }
        .background(
            ZStack {
                LinearGradient(
                    colors: [Color(.systemBackground), brandColor.opacity(0.06)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                RadialGradient(
                    colors: [brandColor.opacity(0.10), .clear],
                    center: .init(x: 0.5, y: 0.20),
                    startRadius: 0,
                    endRadius: 220
                )
                .allowsHitTesting(false)
            }
            .ignoresSafeArea()
        )
        .animation(Motion.entrance, value: isSetupMode)
        .animation(Motion.entrance, value: manager.errorMessage)
        .animation(Motion.entrance, value: manager.isStartingDemo)
        .animation(Motion.state, value: manager.isLoading)
        .animation(Motion.entrance, value: manager.pendingMFAChallenge)
        .animation(Motion.entrance, value: manager.isOIDCAvailable)
        .onAppear {
            serverURL = manager.serverURL
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                if !manager.isStartingDemo {
                    if isSetupMode {
                        focusedField = .serverURL
                    } else if manager.pendingMFAChallenge != nil {
                        focusedField = .recoveryCode
                    } else if shouldShowPasswordFields {
                        focusedField = .username
                    }
                }
            }
        }
        .onChange(of: manager.isStartingDemo) { _, isStarting in
            if isStarting { focusedField = nil }
        }
        .onChange(of: shouldShowPasswordFields) { _, shows in
            // Capabilities resolve after the initial focus fires; drop the
            // keyboard if the fields it targeted just went behind OIDC.
            if !shows { focusedField = nil }
        }
        .task(id: oidcRefreshTaskID) {
            guard !isSetupMode, !manager.serverURL.isEmpty else { return }
            await manager.refreshLoginCapabilities()
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 12) {
            Image("ArcaneLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 76, height: 76)
                .padding(20)
                .glassEffectCompat(in: .rect(cornerRadius: Radius.hero))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.hero, style: .continuous)
                        .stroke(.white.opacity(0.12), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.10), radius: 10, y: 4)
                .scaleEffect(logoAppeared || reduceMotion ? 1.0 : 0.7)
                .opacity(logoAppeared || reduceMotion ? 1.0 : 0.0)
                .onAppear {
                    guard !reduceMotion else {
                        logoAppeared = true
                        return
                    }
                    withAnimation(Motion.logoEntrance.delay(0.08)) {
                        logoAppeared = true
                    }
                }

            VStack(spacing: 8) {
                Text("Arcane")
                    .font(.title.bold())

                if let subtitle = headerSubtitle {
                    Text(subtitle)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .contentTransition(.opacity)
                }

                // The connected server doubles as the "change server" control,
                // so neither needs a row of its own in the form or the actions.
                if showsServerChip {
                    serverChip
                }
            }
        }
    }

    private var headerSubtitle: String? {
        if manager.isStartingDemo {
            return "Setting things up for you…"
        }
        if isSetupMode { return "Connect to your Arcane server" }
        if manager.pendingMFAChallenge != nil {
            return "Use a passkey or a recovery code to finish signing in"
        }
        return "Sign in to continue"
    }

    private var showsServerChip: Bool {
        !isSetupMode && !manager.isStartingDemo && manager.pendingMFAChallenge == nil
    }

    private var serverChip: some View {
        Button {
            focusedField = nil
            withAnimation(Motion.entrance) { showSetup = true }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "server.rack")
                    .font(.footnote)
                Text(serverDisplayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffectCompat(in: .capsule)
        .accessibilityLabel("Server \(serverDisplayName). Change server")
    }

    /// Host (and port) only — the scheme is noise once connected, and the full
    /// URL is what made the old server row wrap on small screens.
    private var serverDisplayName: String {
        let raw = manager.serverURL
        guard let url = URL(string: raw), let host = url.host() else { return raw }
        if let port = url.port { return "\(host):\(port)" }
        return host
    }

    // MARK: - Form

    @ViewBuilder
    private var formCard: some View {
        Group {
            if isSetupMode {
                serverURLForm
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
            } else if manager.pendingMFAChallenge != nil {
                mfaForm
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            } else if shouldShowPasswordFields {
                credentialsForm
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            }
        }
    }

    private var serverURLForm: some View {
        VStack(spacing: 8) {
            FieldRow(icon: "server.rack", label: "Server URL") {
                TextField(
                    "",
                    text: $serverURL,
                    prompt: Text("arcane.example.com").foregroundStyle(.secondary)
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .textContentType(.URL)
                .focused($focusedField, equals: .serverURL)
                .submitLabel(.go)
                .onSubmit { connectToServer() }
                .onChange(of: serverURL) { _, _ in
                    // Drop a stale validation error the moment the user edits the URL.
                    if manager.errorMessage != nil { manager.errorMessage = nil }
                }
            }
            .glassEffectCompat(in: .rect(cornerRadius: Radius.card))

            Text("Include the scheme for a local server — http://192.168.1.50:3000")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    private var credentialsForm: some View {
        VStack(spacing: 0) {
            FieldRow(icon: "person", label: "Username") {
                TextField(
                    "",
                    text: $username,
                    prompt: Text("Username").foregroundStyle(.secondary)
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.username)
                .focused($focusedField, equals: .username)
                .submitLabel(.next)
                .onSubmit { focusedField = .password }
            }

            Divider().padding(.leading, 16)

            FieldRow(icon: "lock", label: "Password") {
                SecureField(
                    "",
                    text: $password,
                    prompt: Text("Password").foregroundStyle(.secondary)
                )
                .textContentType(.password)
                .focused($focusedField, equals: .password)
                .submitLabel(.go)
                .onSubmit { signIn() }
            }
        }
        .glassEffectCompat(in: .rect(cornerRadius: Radius.card))
    }

    // The "what is this" copy lives in the header subtitle, so the card carries
    // only the one thing the user has to type.
    private var mfaForm: some View {
        VStack(spacing: 0) {
            FieldRow(icon: "key.viewfinder", label: "Recovery Code") {
                TextField(
                    "",
                    text: $recoveryCode,
                    prompt: Text("Enter recovery code").foregroundStyle(.secondary)
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.oneTimeCode)
                .focused($focusedField, equals: .recoveryCode)
                .submitLabel(.go)
                .onSubmit { completeMFAWithRecoveryCode() }
            }
        }
        .glassEffectCompat(in: .rect(cornerRadius: Radius.card))
    }

    private func infoBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.blue)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            Button {
                manager.demoExpiredMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(.blue.opacity(0.12), in: .rect(cornerRadius: Radius.standard))
        .transition(.scale(scale: 0.95).combined(with: .opacity))
    }

    // MARK: - Actions

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 10) {
            if isSetupMode {
                setupActions
            } else if manager.pendingMFAChallenge != nil {
                mfaActions
            } else {
                signInActions
            }
        }
    }

    @ViewBuilder
    private var setupActions: some View {
        primaryButton(
            "Connect",
            icon: "arrow.right",
            loading: manager.isLoading && !manager.isStartingDemo,
            action: connectToServer
        )
        .disabled(serverURL.isEmpty || manager.isLoading)

        // Only reachable when the user opened setup from an existing session.
        if mode == .login {
            Button("Cancel") {
                focusedField = nil
                serverURL = manager.serverURL
                withAnimation(Motion.entrance) { showSetup = false }
            }
            .buttonStyle(.borderless)
            .controlSize(.large)
            .tint(.secondary)
        }
    }

    // One prominent action, with every alternative demoted to a single compact
    // row underneath — the old stack put three full-width slabs in a column.
    @ViewBuilder
    private var signInActions: some View {
        if manager.isOIDCAvailable && !showsPasswordForm {
            primaryButton(
                "Continue with \(providerDisplayName)",
                icon: "key.fill",
                loading: manager.isOIDCSigningIn,
                action: signInWithOIDC
            )
            .disabled(manager.isLoading || manager.isOIDCSigningIn)
        } else {
            primaryButton(
                "Sign In",
                icon: "person.fill.checkmark",
                loading: manager.isLoading,
                action: signIn
            )
            .disabled(username.isEmpty || password.isEmpty || manager.isLoading)
        }

        HStack(spacing: 10) {
            secondaryButton(
                "Passkey",
                icon: "person.badge.key.fill",
                loading: manager.isPasskeySigningIn,
                action: signInWithPasskey
            )

            if manager.isOIDCAvailable {
                if showsPasswordForm {
                    secondaryButton(
                        providerDisplayName,
                        icon: "key.fill",
                        loading: manager.isOIDCSigningIn,
                        action: signInWithOIDC
                    )
                } else {
                    secondaryButton(
                        "Password",
                        icon: "lock.fill",
                        loading: false,
                        action: revealPasswordForm
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var mfaActions: some View {
        primaryButton(
            "Continue with Passkey",
            icon: "person.badge.key.fill",
            loading: manager.isPasskeySigningIn,
            action: completeMFAWithPasskey
        )
        .disabled(manager.isLoading || manager.isPasskeySigningIn)

        secondaryButton(
            "Use Recovery Code",
            icon: "key.viewfinder",
            loading: manager.isLoading,
            action: completeMFAWithRecoveryCode
        )
        .disabled(
            recoveryCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || manager.isLoading
                || manager.isPasskeySigningIn
        )

        Button("Back to Sign In") {
            focusedField = nil
            recoveryCode = ""
            manager.cancelPendingMFA()
        }
        .buttonStyle(.borderless)
        .controlSize(.large)
        .tint(.secondary)
    }

    private var providerDisplayName: String {
        let name = manager.oidcInfo?.providerName ?? ""
        return name.isEmpty ? "OIDC" : name
    }

    // MARK: - Action building blocks

    // Both button tiers are plain `.extraLarge` native controls — no forced
    // heights, no custom border shapes. The system sizes them.
    private func primaryButton(
        _ title: String,
        icon: String,
        loading: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                Label(title, systemImage: icon)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .opacity(loading ? 0 : 1)

                if loading {
                    ProgressView().controlSize(.regular)
                }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
        }
        .glassProminentButtonStyleCompat()
        .controlSize(.extraLarge)
    }

    private func secondaryButton(
        _ title: String,
        icon: String,
        loading: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                Label(title, systemImage: icon)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .opacity(loading ? 0 : 1)

                if loading {
                    ProgressView().controlSize(.regular)
                }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
        }
        .glassButtonStyleCompat()
        .controlSize(.extraLarge)
        .disabled(manager.isLoading || manager.isOIDCSigningIn || manager.isPasskeySigningIn)
    }

    // Pinned above the scroll content: the demo is an offer, not a peer of the
    // sign-in action, so it sits out of the form's vertical rhythm entirely.
    private var demoBanner: some View {
        Button {
            Task { await manager.startDemo() }
        } label: {
            HStack(spacing: 8) {
                if manager.isStartingDemo {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "sparkles")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(brandColor)
                }

                Text(manager.isStartingDemo ? "Starting demo…" : "Try the demo")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if !manager.isStartingDemo {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffectCompat(in: .capsule)
        .padding(.top, 4)
        .padding(.bottom, 12)
        .disabled(manager.isLoading)
        .opacity(manager.isLoading && !manager.isStartingDemo ? 0.5 : 1)
        .animation(Motion.state, value: manager.isStartingDemo)
    }

    // MARK: - Intent

    private func connectToServer() {
        focusedField = nil
        manager.configure(serverURL: serverURL)
        withAnimation(Motion.entrance) { showSetup = false }
    }

    private func signIn() {
        focusedField = nil
        Task { await manager.login(username: username, password: password) }
    }

    private func revealPasswordForm() {
        focusedField = nil
        withAnimation(Motion.entrance) { showsPasswordForm = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            focusedField = .username
        }
    }

    private func signInWithOIDC() {
        focusedField = nil
        let anchor = AuthenticationPresentationAnchorProvider.current()
        Task { await manager.loginWithOIDC(anchor: anchor) }
    }

    private func signInWithPasskey() {
        focusedField = nil
        let anchor = AuthenticationPresentationAnchorProvider.current()
        Task { await manager.loginWithPasskey(anchor: anchor) }
    }

    private func completeMFAWithPasskey() {
        focusedField = nil
        let anchor = AuthenticationPresentationAnchorProvider.current()
        Task { await manager.completePendingMFAWithPasskey(anchor: anchor) }
    }

    private func completeMFAWithRecoveryCode() {
        focusedField = nil
        Task { await manager.completePendingMFAWithRecoveryCode(recoveryCode) }
    }
}

enum AuthenticationPresentationAnchorProvider {
    @MainActor
    static func current() -> ASPresentationAnchor {
        let windowScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in windowScenes {
            if let key = scene.windows.first(where: { $0.isKeyWindow }) {
                return key
            }
            if let first = scene.windows.first {
                return first
            }
        }
        guard let scene = windowScenes.first else {
            preconditionFailure("Authentication invoked with no connected window scene")
        }
        return ASPresentationAnchor(windowScene: scene)
    }
}

/// A single-line field: leading glyph, then the control. The old two-line
/// variant (caption label stacked over the field) put three type sizes in one
/// card. Sized by its content — no fixed row height.
private struct FieldRow<Content: View>: View {
    let icon: String
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)

            content
                .font(.body)
                .accessibilityLabel(label)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
    }
}
