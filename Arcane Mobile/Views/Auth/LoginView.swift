import SwiftUI

enum LoginMode {
    case setup   // First-time server URL entry
    case login   // Credentials entry
}

struct LoginView: View {
    @Environment(ArcaneClientManager.self) private var manager
    var mode: LoginMode

    @State private var serverURL: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var showSetup: Bool = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case serverURL, username, password
    }

    private var isSetupMode: Bool { mode == .setup || showSetup }
    private var canEditServer: Bool { mode == .login }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 28) {
                    Spacer(minLength: 0)

                    headerSection

                    formCard

                    if let error = manager.errorMessage {
                        errorBanner(error)
                    }

                    actions

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 24)
                .frame(minHeight: geo.size.height)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
        }
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

    // MARK: - Actions

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 8) {
            if isSetupMode {
                Button(action: connectToServer) {
                    Label("Connect", systemImage: "arrow.right")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.extraLarge)
                .disabled(serverURL.isEmpty || manager.isLoading)

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
