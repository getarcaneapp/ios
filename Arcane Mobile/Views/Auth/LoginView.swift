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
    @State private var showSetup: Bool = false

    @State private var showsPasswordForm: Bool = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case serverURL, username, password
    }

    private var isSetupMode: Bool { mode == .setup || showSetup }

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
            VStack(spacing: 24) {
                Spacer(minLength: 0)

                headerSection

                if !manager.isStartingDemo {
                    formCard
                        .transition(.opacity.combined(with: .move(edge: .top)))

                    if let error = manager.errorMessage {
                        ErrorBanner(message: error)
                    }

                    if let info = manager.demoExpiredMessage {
                        infoBanner(info)
                    }

                    actions
                        .transition(.opacity)
                }

                demoCard

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
            .containerRelativeFrame(.vertical, alignment: .center) { length, _ in length }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
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
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: isSetupMode)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: manager.errorMessage)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: manager.isStartingDemo)
        .animation(.spring(response: 0.3), value: manager.isLoading)
        .onAppear {
            serverURL = manager.serverURL
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                if !manager.isStartingDemo {
                    focusedField = isSetupMode ? .serverURL : .username
                }
            }
        }
        .onChange(of: manager.isStartingDemo) { _, isStarting in
            if isStarting { focusedField = nil }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 14) {
            Image("ArcaneLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)
                .padding(20)
                .glassEffect(.regular, in: .rect(cornerRadius: 24))
                .overlay(
                    RoundedRectangle(cornerRadius: 24)
                        .stroke(.white.opacity(0.12), lineWidth: 1)
                )
                .shadow(color: brandColor.opacity(0.12), radius: 28, y: 10)
                .shadow(color: .black.opacity(0.10), radius: 8, y: 3)

            VStack(spacing: 4) {
                Text("Arcane")
                    .font(.title.bold())

                if let subtitle = headerSubtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                }
            }
        }
    }

    private var headerSubtitle: String? {
        if manager.isStartingDemo {
            return "Setting things up for you…"
        }
        return isSetupMode ? "Connect to your Arcane server" : nil
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
            } else {
                credentialsForm
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            }
        }
    }

    private var serverURLForm: some View {
        VStack(spacing: 0) {
            FieldRow(icon: "server.rack", label: "Server URL") {
                TextField(
                    "",
                    text: $serverURL,
                    prompt: Text("https://arcane.example.com").foregroundStyle(.secondary)
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .focused($focusedField, equals: .serverURL)
                .submitLabel(.go)
                .onSubmit { connectToServer() }
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private var credentialsForm: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Server", systemImage: "server.rack")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(manager.serverURL)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(shouldShowPasswordFields ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, shouldShowPasswordFields ? 12 : 10)

            if shouldShowPasswordFields {
                Divider().padding(.leading, 16)

                FieldRow(icon: "person", label: "Username") {
                    TextField(
                        "",
                        text: $username,
                        prompt: Text("Username").foregroundStyle(.secondary)
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
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
                    .focused($focusedField, equals: .password)
                    .submitLabel(.go)
                    .onSubmit { signIn() }
                }
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
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
        .padding(12)
        .background(.blue.opacity(0.12), in: .rect(cornerRadius: 12))
        .transition(.scale(scale: 0.95).combined(with: .opacity))
    }

    // MARK: - Actions

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 10) {
            if isSetupMode {
                Button(action: connectToServer) {
                    ZStack {
                        Label("Connect", systemImage: "arrow.right")
                            .opacity(manager.isLoading && !manager.isStartingDemo ? 0 : 1)
                        if manager.isLoading && !manager.isStartingDemo {
                            ProgressView().controlSize(.regular)
                        }
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.extraLarge)
                .disabled(serverURL.isEmpty || manager.isLoading)
            } else {
                if manager.isOIDCAvailable {
                    if !showsPasswordForm {
                        oidcPrimaryButton
                    }
                    passwordDisclosure
                }

                if shouldShowPasswordFields {
                    Button(action: signIn) {
                        ZStack {
                            Label("Sign In", systemImage: "person.fill.checkmark")
                                .opacity(manager.isLoading ? 0 : 1)
                            if manager.isLoading {
                                ProgressView().controlSize(.regular)
                            }
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.extraLarge)
                    .disabled(username.isEmpty || password.isEmpty || manager.isLoading)
                }

                Button("Change Server") {
                    focusedField = nil
                    withAnimation(.spring(response: 0.4)) { showSetup = true }
                }
                .buttonStyle(.borderless)
                .controlSize(.large)
                .tint(.secondary)
            }
        }
    }

    private var providerDisplayName: String {
        let name = manager.oidcInfo?.providerName ?? ""
        return name.isEmpty ? "OIDC" : name
    }

    @ViewBuilder
    private var oidcPrimaryButton: some View {
        Button(action: signInWithOIDC) {
            ZStack {
                Label("Continue with \(providerDisplayName)", systemImage: "key.fill")
                    .opacity(manager.isOIDCSigningIn ? 0 : 1)
                if manager.isOIDCSigningIn {
                    ProgressView().controlSize(.regular)
                }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.extraLarge)
        .disabled(manager.isLoading || manager.isOIDCSigningIn)
    }

    @ViewBuilder
    private var passwordDisclosure: some View {
        Button {
            focusedField = nil
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                showsPasswordForm.toggle()
            }
            if showsPasswordForm {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    focusedField = .username
                }
            }
        } label: {
            Label(
                showsPasswordForm ? "Hide password sign in" : "Sign in with username and password",
                systemImage: showsPasswordForm ? "chevron.up" : "chevron.down"
            )
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .tint(.secondary)
        .disabled(manager.isLoading || manager.isOIDCSigningIn)
    }

    private var demoCard: some View {
        Button {
            Task { await manager.startDemo() }
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(brandColor.opacity(0.18))
                    Image(systemName: "sparkles")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(brandColor)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(manager.isStartingDemo ? "Starting demo…" : "Try the demo")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(manager.isStartingDemo
                         ? "This usually takes about 30 seconds."
                         : "Temporary instance for ~10 minutes. No account needed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if manager.isStartingDemo {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(brandColor)
                }
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(brandColor.opacity(0.22), lineWidth: 1)
        )
        .disabled(manager.isLoading)
        .opacity(manager.isLoading && !manager.isStartingDemo ? 0.5 : 1)
        .animation(.spring(response: 0.3), value: manager.isStartingDemo)
    }

    // MARK: - Intent

    private func connectToServer() {
        focusedField = nil
        manager.configure(serverURL: serverURL)
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { showSetup = false }
    }

    private func signIn() {
        focusedField = nil
        Task { await manager.login(username: username, password: password) }
    }

    private func signInWithOIDC() {
        focusedField = nil
        let anchor = OIDCPresentationAnchorProvider.current()
        Task { await manager.loginWithOIDC(anchor: anchor) }
    }
}

private enum OIDCPresentationAnchorProvider {
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
            preconditionFailure("OIDC sign-in invoked with no connected window scene")
        }
        return ASPresentationAnchor(windowScene: scene)
    }
}

private struct FieldRow<Content: View>: View {
    let icon: String
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(label, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content
                .font(.body)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
