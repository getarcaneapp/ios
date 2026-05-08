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

    var body: some View {
        ZStack {
            // Gradient background
            LinearGradient(
                colors: [Color(.systemBackground), Color.accentColor.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 32) {
                    // Logo / header
                    VStack(spacing: 12) {
                        Image("ArcaneLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 72, height: 72)
                            .padding(20)
                            .glassEffect(.regular, in: .circle)

                        Text("Arcane")
                            .font(.largeTitle.bold())

                        Text(mode == .setup ? "Connect to your server" : "Sign in to continue")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 48)

                    // Form card
                    GlassEffectContainer(spacing: 12) {
                        VStack(spacing: 0) {
                            if mode == .setup || showSetup {
                                serverURLSection
                            } else {
                                credentialsSection
                            }
                        }
                        .glassEffect(.regular, in: .rect(cornerRadius: 20))
                        .padding(.horizontal, 24)
                    }

                    // Error message
                    if let error = manager.errorMessage {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                            Text(error)
                                .font(.subheadline)
                                .foregroundStyle(.red)
                        }
                        .padding(.horizontal, 24)
                    }

                    // Action buttons
                    VStack(spacing: 12) {
                        if mode == .setup || showSetup {
                            Button(action: connectToServer) {
                                Label("Connect", systemImage: "arrow.right.circle.fill")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                            }
                            .buttonStyle(.glassProminent)
                            .padding(.horizontal, 24)
                            .disabled(serverURL.isEmpty || manager.isLoading)
                        } else {
                            Button(action: signIn) {
                                Group {
                                    if manager.isLoading {
                                        ProgressView()
                                            .tint(.white)
                                    } else {
                                        Label("Sign In", systemImage: "person.fill.checkmark")
                                    }
                                }
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                            }
                            .buttonStyle(.glassProminent)
                            .padding(.horizontal, 24)
                            .disabled(username.isEmpty || password.isEmpty || manager.isLoading)

                            Button {
                                withAnimation { showSetup = true }
                            } label: {
                                Text("Change Server")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.bottom, 32)
                }
            }
        }
        .onAppear {
            serverURL = manager.serverURL
        }
    }

    // MARK: - Server URL section
    private var serverURLSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("Server URL", systemImage: "server.rack")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 8)

            Divider().padding(.horizontal, 16)

            TextField("https://arcane.example.com", text: $serverURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .padding(16)
        }
    }

    // MARK: - Credentials section
    private var credentialsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("Server", systemImage: "server.rack")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 16)

            Text(manager.serverURL)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

            Divider().padding(.horizontal, 16)

            Label("Username", systemImage: "person")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 4)

            TextField("Username", text: $username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

            Divider().padding(.horizontal, 16)

            Label("Password", systemImage: "lock")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 4)

            SecureField("Password", text: $password)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .onSubmit { signIn() }
        }
    }

    // MARK: - Actions
    private func connectToServer() {
        manager.configure(serverURL: serverURL)
        withAnimation { showSetup = false }
    }

    private func signIn() {
        Task { await manager.login(username: username, password: password) }
    }
}
