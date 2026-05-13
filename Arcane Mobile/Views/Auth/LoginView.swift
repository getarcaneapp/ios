import SwiftUI
import Arcane
import AuthenticationServices

enum LoginMode {
    case setup   // First-time server URL entry
    case login   // Credentials entry
}

struct LoginView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
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
    private var canEditServer: Bool { mode == .login }

    // When OIDC is enabled, the password form is hidden behind a disclosure
    // so the provider button is the primary action. The user can still reveal
    // it to sign in locally (e.g. admin fallback).
    private var shouldShowPasswordFields: Bool {
        !manager.isOIDCAvailable || showsPasswordForm
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Spacer(minLength: 0)

                headerSection

                formCard

                if let error = manager.errorMessage {
                    errorBanner(error)
                }

                if let info = manager.demoExpiredMessage {
                    infoBanner(info)
                }

                actions

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
            LinearGradient(
                colors: [Color(.systemBackground), Color.accentColor.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: isSetupMode)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: manager.errorMessage)
        .animation(.spring(response: 0.3), value: manager.isLoading)
        .onAppear {
            serverURL = manager.serverURL
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                focusedField = isSetupMode ? .serverURL : .username
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 16) {
            Image("ArcaneLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)
                .padding(20)
                .background(.ultraThinMaterial, in: .circle)
                .overlay(Circle().stroke(.white.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.1), radius: 12, y: 4)

            VStack(spacing: 4) {
                Text("Arcane")
                    .font(.largeTitle.bold())

                Text(isSetupMode ? "Connect to your server" : "Sign in to continue")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
        }
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
                TextField("https://arcane.example.com", text: $serverURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .focused($focusedField, equals: .serverURL)
                    .submitLabel(.go)
                    .onSubmit { connectToServer() }
            }
        }
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 14))
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
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if shouldShowPasswordFields {
                Divider().padding(.leading, 16)

                FieldRow(icon: "person", label: "Username") {
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .username)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .password }
                }

                Divider().padding(.leading, 16)

                FieldRow(icon: "lock", label: "Password") {
                    SecureField("Password", text: $password)
                        .focused($focusedField, equals: .password)
                        .submitLabel(.go)
                        .onSubmit { signIn() }
                }
            }
        }
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 14))
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.red)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.red.opacity(0.12), in: .rect(cornerRadius: 12))
        .transition(.scale(scale: 0.95).combined(with: .opacity))
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
        VStack(spacing: 8) {
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

                demoSection

                if canEditServer {
                    Button("Cancel") {
                        focusedField = nil
                        withAnimation(.spring(response: 0.4)) { showSetup = false }
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.large)
                    .tint(.secondary)
                }
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
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                VStack { Divider() }
                Text("OR")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                VStack { Divider() }
            }
            .padding(.vertical, 4)

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
    }

    @ViewBuilder
    private var demoSection: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                VStack { Divider() }
                Text("OR")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                VStack { Divider() }
            }
            .padding(.vertical, 4)

            Button {
                Task { await manager.startDemo() }
            } label: {
                ZStack {
                    Label("Try the demo", systemImage: "sparkles")
                        .opacity(manager.isStartingDemo ? 0 : 1)
                    if manager.isStartingDemo {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Spinning up your demo…")
                                .font(.subheadline)
                        }
                    }
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(.accentColor)
            .disabled(manager.isLoading)

            Text(manager.isStartingDemo
                 ? "This usually takes about 30 seconds."
                 : "Spins up a temporary instance for ~10 minutes. No account needed.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .padding(.top, 4)
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
