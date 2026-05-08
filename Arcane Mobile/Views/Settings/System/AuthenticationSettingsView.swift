import SwiftUI
import Arcane

struct AuthenticationSettingsView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager

    // Local Auth
    @State private var authLocalEnabled = true
    @State private var authSessionTimeout = "1440"
    @State private var authPasswordPolicy = "strong"

    // OIDC
    @State private var oidcEnabled = false
    @State private var oidcProviderName = ""
    @State private var oidcIssuerUrl = ""
    @State private var oidcClientId = ""
    @State private var oidcClientSecret = ""
    @State private var oidcScopes = "openid email profile"
    @State private var oidcAdminClaim = ""
    @State private var oidcAdminValue = ""
    @State private var oidcSkipTlsVerify = false
    @State private var oidcAutoRedirectToProvider = false
    @State private var oidcMergeAccounts = false
    @State private var oidcProviderLogoUrl = ""

    @State private var isLoading = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var savedMessage: String?

    // Env-var override status
    @State private var oidcEnvForced = false
    @State private var oidcEnvConfigured = false

    var body: some View {
        Form {
            Section {
                Toggle("Local Auth Enabled", isOn: $authLocalEnabled)
            } header: {
                Label("Local Authentication", systemImage: "person.badge.key")
            }

            Section {
                HStack {
                    Text("Session Timeout (min)")
                    Spacer()
                    TextField("1440", text: $authSessionTimeout)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 100)
                        .foregroundStyle(.secondary)
                }
                Picker("Password Policy", selection: $authPasswordPolicy) {
                    Text("Basic").tag("basic")
                    Text("Standard").tag("standard")
                    Text("Strong").tag("strong")
                }
            } header: {
                Label("Session", systemImage: "clock")
            }

            if oidcEnvForced {
                Section {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Configured by Environment Variables")
                                .font(.subheadline.weight(.semibold))
                            Text("OIDC settings are managed via OS environment variables on the server and cannot be modified here.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section {
                Toggle("OIDC Enabled", isOn: $oidcEnabled)
                TextField("Provider Name", text: $oidcProviderName)
                    .autocapitalization(.none)
                TextField("Provider Logo URL", text: $oidcProviderLogoUrl)
                    .keyboardType(.URL)
                    .autocapitalization(.none)
                TextField("Issuer URL", text: $oidcIssuerUrl)
                    .keyboardType(.URL)
                    .autocapitalization(.none)
                TextField("Client ID", text: $oidcClientId)
                    .autocapitalization(.none)
                SecureField("Client Secret", text: $oidcClientSecret)
                TextField("Scopes", text: $oidcScopes)
                    .autocapitalization(.none)
            } header: {
                Label("OIDC Provider", systemImage: "lock.shield")
            }
            .disabled(oidcEnvForced)

            Section {
                TextField("Admin Claim", text: $oidcAdminClaim)
                    .autocapitalization(.none)
                TextField("Admin Value", text: $oidcAdminValue)
                    .autocapitalization(.none)
                Toggle("Skip TLS Verify", isOn: $oidcSkipTlsVerify)
                Toggle("Auto-Redirect to Provider", isOn: $oidcAutoRedirectToProvider)
                Toggle("Merge Accounts", isOn: $oidcMergeAccounts)
            } header: {
                Text("OIDC Options")
            }
            .disabled(oidcEnvForced)

            if let error = errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            }

            if let msg = savedMessage {
                Section {
                    Label(msg, systemImage: "checkmark.circle").foregroundStyle(.green)
                }
            }

            Section {
                Button {
                    Task { await save() }
                } label: {
                    HStack {
                        Spacer()
                        if isSaving {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Text("Save")
                        }
                        Spacer()
                    }
                }
                .disabled(isSaving)
            }
        }
        .navigationTitle("Authentication")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadSettings() }
    }

    // MARK: - API

    private func loadSettings() async {
        guard let client = manager.client else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let path = client.rest.environmentPath(manager.activeEnvironmentID, "settings")
            let rawData = try await client.transport.rawRequest(path, body: Optional<String>.none)
            let dtos = try JSONDecoder().decode([PublicSetting].self, from: rawData)
            let dict = Dictionary(uniqueKeysWithValues: dtos.map { ($0.key, $0.value) })
            authLocalEnabled = dict["authLocalEnabled"]?.lowercased() == "true"
            authSessionTimeout = dict["authSessionTimeout"] ?? "1440"
            authPasswordPolicy = dict["authPasswordPolicy"] ?? "strong"
            oidcEnabled = dict["oidcEnabled"]?.lowercased() == "true"
            oidcProviderName = dict["oidcProviderName"] ?? ""
            oidcIssuerUrl = dict["oidcIssuerUrl"] ?? ""
            oidcClientId = dict["oidcClientId"] ?? ""
            oidcClientSecret = dict["oidcClientSecret"] ?? ""
            oidcScopes = dict["oidcScopes"] ?? "openid email profile"
            oidcAdminClaim = dict["oidcAdminClaim"] ?? ""
            oidcAdminValue = dict["oidcAdminValue"] ?? ""
            oidcSkipTlsVerify = dict["oidcSkipTlsVerify"]?.lowercased() == "true"
            oidcAutoRedirectToProvider = dict["oidcAutoRedirectToProvider"]?.lowercased() == "true"
            oidcMergeAccounts = dict["oidcMergeAccounts"]?.lowercased() == "true"
            oidcProviderLogoUrl = dict["oidcProviderLogoUrl"] ?? ""

            await loadOidcStatus()
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func loadOidcStatus() async {
        guard let client = manager.client else { return }
        do {
            let rawData = try await client.transport.rawRequest("oidc/status", body: Optional<String>.none, authorized: false)
            let status = try JSONDecoder().decode(OidcStatusInfo.self, from: rawData)
            oidcEnvForced = status.envForced
            oidcEnvConfigured = status.envConfigured ?? false
        } catch {
            // Silently ignore — fields remain editable if status check fails
        }
    }

    private func save() async {
        guard let client = manager.client else { return }
        isSaving = true
        errorMessage = nil
        savedMessage = nil
        defer { isSaving = false }
        do {
            let body = SettingsUpdate(
                authLocalEnabled: String(authLocalEnabled),
                authPasswordPolicy: authPasswordPolicy,
                authSessionTimeout: authSessionTimeout,
                oidcAdminClaim: oidcAdminClaim.isEmpty ? nil : oidcAdminClaim,
                oidcAdminValue: oidcAdminValue.isEmpty ? nil : oidcAdminValue,
                oidcAutoRedirectToProvider: String(oidcAutoRedirectToProvider),
                oidcClientId: oidcClientId.isEmpty ? nil : oidcClientId,
                oidcClientSecret: oidcClientSecret.isEmpty ? nil : oidcClientSecret,
                oidcEnabled: String(oidcEnabled),
                oidcIssuerUrl: oidcIssuerUrl.isEmpty ? nil : oidcIssuerUrl,
                oidcMergeAccounts: String(oidcMergeAccounts),
                oidcProviderLogoUrl: oidcProviderLogoUrl.isEmpty ? nil : oidcProviderLogoUrl,
                oidcProviderName: oidcProviderName.isEmpty ? nil : oidcProviderName,
                oidcScopes: oidcScopes.isEmpty ? nil : oidcScopes,
                oidcSkipTlsVerify: String(oidcSkipTlsVerify)
            )
            let path = client.rest.environmentPath(manager.activeEnvironmentID, "settings")
            let _: [PublicSetting] = try await client.rest.put(path, body: body)
            if let cached = manager.cached {
                await cached.invalidate(envID: manager.activeEnvironmentID, paths: [path, path + "*"])
            }
            savedMessage = "Authentication settings saved"
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { savedMessage = nil }
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }
}
