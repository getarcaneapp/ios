import SwiftUI
import Arcane
import AuthenticationServices

enum LoginMode {
    case setup   // First-time server URL entry
    case login   // Credentials entry
}

struct LoginView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(ConnectionProfileStore.self) private var profileStore
    @SwiftUI.Environment(\.isLaunchSplashPresented) private var isLaunchSplashPresented
    @AppStorage("accentColorHex") private var accentColorHex: String = ""
    var mode: LoginMode

    @State private var serverURL: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var recoveryCode: String = ""
    @State private var showSetup: Bool = false
    @State private var showsConnectionProfiles = false

    @State private var showsPasswordForm: Bool = false
    @State private var pendingPasswordCredentialChange: PendingPasswordCredentialChange?
    @State private var savedSignInOffer: SavedSignInOffer?
    @State private var isUsingSavedSignIn = false
    @State private var savedSignInAttemptID: UUID?
    @State private var logoAppeared: Bool = false
    @FocusState private var focusedField: Field?
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Field: Hashable {
        case serverURL, username, password, recoveryCode
    }

    private struct PendingPasswordCredentialChange {
        let serverURL: String
        let username: String
        let password: String
    }

    private struct SavedSignInOffer: CustomStringConvertible, CustomDebugStringConvertible {
        let profile: ConnectionProfile
        let credential: SyncedConnectionCredential

        var description: String {
            "SavedSignInOffer(profileID: \(profile.id), credentials: <redacted>)"
        }

        var debugDescription: String { description }
    }

    private var isSetupMode: Bool { mode == .setup || showSetup }

    private var oidcRefreshTaskID: String {
        "\(isSetupMode)-\(manager.serverURL)-\(manager.clientGeneration)"
    }

    // When OIDC is enabled, the password form is hidden behind a disclosure
    // so the provider button is the primary action. Servers can remove the
    // local password path entirely through their public auth settings.
    private var shouldShowPasswordFields: Bool {
        manager.isLocalAuthAvailable && (!manager.isOIDCAvailable || showsPasswordForm)
    }

    private var isSavedSignInOfferPresented: Binding<Bool> {
        Binding(
            get: { savedSignInOffer != nil },
            set: { isPresented in
                if !isPresented { savedSignInOffer = nil }
            }
        )
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
            .background {
                Color.clear
                    .contentShape(.rect)
                    .onTapGesture(perform: dismissKeyboard)
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .top, spacing: 0) {
            if manager.pendingMFAChallenge == nil {
                demoBanner
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if focusedField != nil {
                Button("Done", action: dismissKeyboard)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
        .sheet(isPresented: $showsConnectionProfiles) {
            NavigationStack {
                ConnectionProfilesView(suggestedServerURL: serverURL) { profile in
                    connect(using: profile)
                }
            }
            .toastHost(reservesTabBarSpace: false)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .alert(
            "Use Saved Sign-In?",
            isPresented: isSavedSignInOfferPresented,
            presenting: savedSignInOffer
        ) { offer in
            Button("Use Saved Sign-In") {
                useSavedSignIn(offer)
            }
            Button("Not Now", role: .cancel) {
                savedSignInOffer = nil
            }
        } message: { offer in
            Text("Use the sign-in saved in iCloud for \(offer.profile.name)?")
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
        .animation(Motion.state, value: isUsingSavedSignIn)
        .animation(Motion.entrance, value: manager.pendingMFAChallenge)
        .animation(Motion.entrance, value: manager.isOIDCAvailable)
        .animation(Motion.entrance, value: manager.isLocalAuthAvailable)
        .onAppear {
            serverURL = manager.serverURL
        }
        .onChange(of: manager.isStartingDemo) { _, isStarting in
            if isStarting { focusedField = nil }
        }
        .onChange(of: shouldShowPasswordFields) { _, shows in
            // Capabilities resolve after the initial focus fires; drop the
            // keyboard if the fields it targeted just went behind OIDC.
            if !shows { focusedField = nil }
        }
        .onChange(of: manager.isLocalAuthAvailable) { _, isAvailable in
            guard !isAvailable else { return }
            savedSignInOffer = nil
            username = ""
            password = ""
            isUsingSavedSignIn = false
            savedSignInAttemptID = nil
        }
        .onChange(of: profileStore.syncedCredentialProfileIDs) { previousIDs, currentIDs in
            guard !isSetupMode,
                  !isLaunchSplashPresented,
                  username.isEmpty,
                  password.isEmpty,
                  let profile = profileStore.profile(matching: manager.serverURL),
                  !previousIDs.contains(profile.id),
                  currentIDs.contains(profile.id) else { return }
            offerSavedCredential(for: profile)
        }
        .task(id: oidcRefreshTaskID) {
            guard !isSetupMode, !manager.serverURL.isEmpty else { return }
            await manager.refreshLoginCapabilities()
        }
        .task(id: isLaunchSplashPresented) {
            guard !isLaunchSplashPresented else {
                focusedField = nil
                return
            }
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }
            guard !manager.isStartingDemo else { return }
            if !isSetupMode, savedSignInOffer == nil {
                offerSavedCredential(for: profileStore.profile(matching: manager.serverURL))
            }
            if savedSignInOffer != nil {
                focusedField = nil
                return
            }
            if isSetupMode {
                focusedField = .serverURL
            } else if manager.pendingMFAChallenge != nil {
                focusedField = .recoveryCode
            } else if shouldShowPasswordFields {
                if username.isEmpty {
                    focusedField = .username
                } else if password.isEmpty {
                    focusedField = .password
                }
            }
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

            Button {
                focusedField = nil
                showsConnectionProfiles = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "person.crop.rectangle.stack.fill")
                        .foregroundStyle(brandColor)
                        .frame(width: 24)
                    Text("Connection Profiles")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .glassEffectCompat(in: .rect(cornerRadius: Radius.card))
            .accessibilityHint("Opens saved Arcane server profiles")
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
        if manager.isOIDCAvailable && (!manager.isLocalAuthAvailable || !showsPasswordForm) {
            primaryButton(
                "Continue with \(providerDisplayName)",
                icon: "key.fill",
                loading: manager.isOIDCSigningIn,
                action: signInWithOIDC
            )
            .disabled(manager.isLoading || manager.isOIDCSigningIn)
        } else if manager.isLocalAuthAvailable {
            primaryButton(
                "Sign In",
                icon: "person.fill.checkmark",
                loading: manager.isLoading || isUsingSavedSignIn,
                action: signIn
            )
            .disabled(
                username.isEmpty
                    || password.isEmpty
                    || manager.isLoading
                    || isUsingSavedSignIn
            )
        }

        HStack(spacing: 10) {
            secondaryButton(
                "Passkey",
                icon: "person.badge.key.fill",
                loading: manager.isPasskeySigningIn,
                action: signInWithPasskey
            )

            if manager.isOIDCAvailable && manager.isLocalAuthAvailable {
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
            pendingPasswordCredentialChange = nil
            manager.cancelPendingMFA()
        }
        .buttonStyle(.borderless)
        .controlSize(.large)
        .tint(.secondary)
    }

    private var providerDisplayName: String {
        let name = manager.loginCapabilities?.oidcProviderName ?? ""
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
        guard manager.errorMessage == nil else { return }
        serverURL = manager.serverURL
        do {
            let profile = try profileStore.saveConnectedServer(manager.serverURL)
            offerSavedCredential(for: profile)
        } catch {
            resetPasswordSignIn()
            showToast(.info("Connected server wasn't saved as a profile"))
        }
        withAnimation(Motion.entrance) { showSetup = false }
    }

    private func dismissKeyboard() {
        focusedField = nil
    }

    private func connect(using profile: ConnectionProfile) {
        focusedField = nil
        resetPasswordSignIn()
        serverURL = profile.serverURL
        manager.configure(serverURL: profile.serverURL)
        guard manager.errorMessage == nil else { return }
        withAnimation(Motion.entrance) { showSetup = false }
        // Let the profile picker finish dismissing before presenting the
        // native saved-sign-in alert from the login screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard profileStore.profile(matching: manager.serverURL)?.id == profile.id else { return }
            offerSavedCredential(for: profile)
        }
    }

    private func signIn() {
        guard manager.isLocalAuthAvailable else { return }
        focusedField = nil
        let pendingChange = PendingPasswordCredentialChange(
            serverURL: manager.serverURL,
            username: username,
            password: password
        )
        pendingPasswordCredentialChange = pendingChange
        Task {
            await performPasswordSignIn(pendingChange)
        }
    }

    private func revealPasswordForm() {
        guard manager.isLocalAuthAvailable else { return }
        focusedField = nil
        withAnimation(Motion.entrance) { showsPasswordForm = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            focusedField = username.isEmpty ? .username : (password.isEmpty ? .password : nil)
        }
    }

    private func signInWithOIDC() {
        focusedField = nil
        pendingPasswordCredentialChange = nil
        let anchor = AuthenticationPresentationAnchorProvider.current()
        Task { await manager.loginWithOIDC(anchor: anchor) }
    }

    private func signInWithPasskey() {
        focusedField = nil
        pendingPasswordCredentialChange = nil
        let anchor = AuthenticationPresentationAnchorProvider.current()
        Task { await manager.loginWithPasskey(anchor: anchor) }
    }

    private func completeMFAWithPasskey() {
        focusedField = nil
        let anchor = AuthenticationPresentationAnchorProvider.current()
        let pendingChange = pendingPasswordCredentialChange
        Task {
            await manager.completePendingMFAWithPasskey(anchor: anchor)
            if let pendingChange, manager.authState == .authenticated {
                pendingPasswordCredentialChange = nil
                savePasswordSignIn(pendingChange)
            }
        }
    }

    private func completeMFAWithRecoveryCode() {
        focusedField = nil
        let pendingChange = pendingPasswordCredentialChange
        Task {
            await manager.completePendingMFAWithRecoveryCode(recoveryCode)
            if let pendingChange, manager.authState == .authenticated {
                pendingPasswordCredentialChange = nil
                savePasswordSignIn(pendingChange)
            }
        }
    }

    private func offerSavedCredential(for profile: ConnectionProfile?) {
        resetPasswordSignIn()

        guard manager.isLocalAuthAvailable, let profile else { return }
        do {
            guard let credential = try profileStore.syncedCredential(for: profile) else { return }
            savedSignInOffer = SavedSignInOffer(profile: profile, credential: credential)
        } catch {
            showToast(.error(error.localizedDescription))
        }
    }

    private func resetPasswordSignIn() {
        pendingPasswordCredentialChange = nil
        savedSignInOffer = nil
        username = ""
        password = ""
        showsPasswordForm = false
        isUsingSavedSignIn = false
        savedSignInAttemptID = nil
    }

    private func useSavedSignIn(_ offer: SavedSignInOffer) {
        savedSignInOffer = nil
        focusedField = nil
        username = offer.credential.username
        password = offer.credential.password
        withAnimation(Motion.entrance) { showsPasswordForm = true }
        isUsingSavedSignIn = true
        let attemptID = UUID()
        savedSignInAttemptID = attemptID

        Task {
            await manager.refreshLoginCapabilities()
            guard savedSignInAttemptID == attemptID else { return }
            guard manager.isLocalAuthAvailable else {
                resetPasswordSignIn()
                showToast(.info("Password sign-in is disabled on \(offer.profile.name)"))
                return
            }
            guard profileStore.profile(matching: manager.serverURL)?.id == offer.profile.id else {
                resetPasswordSignIn()
                return
            }

            let pendingChange = PendingPasswordCredentialChange(
                serverURL: offer.profile.serverURL,
                username: offer.credential.username,
                password: offer.credential.password
            )
            pendingPasswordCredentialChange = pendingChange
            await performPasswordSignIn(pendingChange)
            guard savedSignInAttemptID == attemptID else { return }
            savedSignInAttemptID = nil
            isUsingSavedSignIn = false
        }
    }

    private func performPasswordSignIn(_ pendingChange: PendingPasswordCredentialChange) async {
        await manager.login(username: pendingChange.username, password: pendingChange.password)
        if manager.authState == .authenticated {
            pendingPasswordCredentialChange = nil
            savePasswordSignIn(pendingChange)
        } else if manager.pendingMFAChallenge == nil {
            pendingPasswordCredentialChange = nil
        }
    }

    private func savePasswordSignIn(_ pendingChange: PendingPasswordCredentialChange) {
        guard manager.authState == .authenticated else { return }
        guard let currentURL = try? ConnectionProfileSync.normalizedServerURL(manager.serverURL),
              let attemptedURL = try? ConnectionProfileSync.normalizedServerURL(pendingChange.serverURL),
              currentURL == attemptedURL else { return }

        do {
            let credential = try SyncedConnectionCredential(
                username: pendingChange.username,
                password: pendingChange.password
            )
            try profileStore.saveConnectedServer(
                pendingChange.serverURL,
                credential: credential
            )
        } catch {
            showToast(.error(error.localizedDescription))
        }
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
