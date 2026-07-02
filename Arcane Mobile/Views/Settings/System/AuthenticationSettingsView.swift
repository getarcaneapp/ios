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
    @State private var oidcGroupsClaim = ""
    @State private var oidcSkipTlsVerify = false
    @State private var oidcAutoRedirectToProvider = false
    @State private var oidcMergeAccounts = false
    @State private var oidcProviderLogoUrl = ""

    @State private var isLoading = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    // Env-var override status
    @State private var oidcEnvForced = false
    @State private var oidcEnvConfigured = false

    var body: some View {
        Form {
            Section {
                Toggle("Local Auth Enabled", isOn: $authLocalEnabled)
                FormNumberField(
                    title: "Session Timeout",
                    placeholder: "1440",
                    text: $authSessionTimeout,
                    minValue: 15,
                    maxValue: 1440
                )
                FormPicker(
                    title: "Password Policy",
                    selection: $authPasswordPolicy
                ) {
                    Text("Basic").tag("basic")
                    Text("Standard").tag("standard")
                    Text("Strong").tag("strong")
                }
            } header: {
                Label("Local Authentication", systemImage: "person.badge.key")
            } footer: {
                Text("Session length in minutes (15–1440). Stronger policies require more complex local passwords.")
            }

            Section {
                Toggle("OIDC Enabled", isOn: $oidcEnabled)
                FormTextField(
                    title: "Provider Name",
                    placeholder: "Okta",
                    text: $oidcProviderName,
                    autocapitalization: .never,
                    autocorrectionDisabled: true
                )
                FormTextField(
                    title: "Provider Logo URL",
                    placeholder: "https://...",
                    text: $oidcProviderLogoUrl,
                    keyboardType: .URL,
                    textContentType: .URL,
                    autocapitalization: .never,
                    autocorrectionDisabled: true
                )
                FormTextField(
                    title: "Issuer URL",
                    placeholder: "https://issuer.example.com",
                    text: $oidcIssuerUrl,
                    keyboardType: .URL,
                    textContentType: .URL,
                    autocapitalization: .never,
                    autocorrectionDisabled: true
                )
                FormTextField(
                    title: "Client ID",
                    placeholder: "OIDC client ID",
                    text: $oidcClientId,
                    autocapitalization: .never,
                    autocorrectionDisabled: true
                )
                FormSecureField(title: "Client Secret", placeholder: "OIDC client secret", text: $oidcClientSecret)
                FormTextField(
                    title: "Scopes",
                    placeholder: "openid email profile",
                    text: $oidcScopes,
                    autocapitalization: .never,
                    autocorrectionDisabled: true,
                    layout: .stacked
                )
            } header: {
                Label("OIDC Provider", systemImage: "lock.shield")
            } footer: {
                if oidcEnvForced {
                    Label("OIDC is managed by server environment variables and can't be edited here.", systemImage: "lock.fill")
                }
            }
            .disabled(oidcEnvForced)

            Section {
                FormTextField(
                    title: "Groups Claim",
                    placeholder: "groups",
                    text: $oidcGroupsClaim,
                    autocapitalization: .never,
                    autocorrectionDisabled: true
                )
                Toggle("Skip TLS Verify", isOn: $oidcSkipTlsVerify)
                Toggle("Auto-Redirect to Provider", isOn: $oidcAutoRedirectToProvider)
                Toggle("Merge Accounts", isOn: $oidcMergeAccounts)
            } header: {
                Text("OIDC Options")
            } footer: {
                Text("Groups Claim is the token claim read for group memberships. Map groups to roles in the Arcane web app.")
            }
            .disabled(oidcEnvForced)

            if let error = errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
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
            let dict = Dictionary(dtos.map { ($0.key, $0.value) }, uniquingKeysWith: { _, new in new })
            authLocalEnabled = dict["authLocalEnabled"]?.lowercased() == "true"
            authSessionTimeout = dict["authSessionTimeout"] ?? "1440"
            authPasswordPolicy = dict["authPasswordPolicy"] ?? "strong"
            oidcEnabled = dict["oidcEnabled"]?.lowercased() == "true"
            oidcProviderName = dict["oidcProviderName"] ?? ""
            oidcIssuerUrl = dict["oidcIssuerUrl"] ?? ""
            oidcClientId = dict["oidcClientId"] ?? ""
            oidcClientSecret = dict["oidcClientSecret"] ?? ""
            oidcScopes = dict["oidcScopes"] ?? "openid email profile"
            oidcGroupsClaim = dict["oidcGroupsClaim"] ?? ""
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
            let status = try JSONDecoder().decode(OIDCStatusInfo.self, from: rawData)
            oidcEnvForced = status.envForced
            oidcEnvConfigured = status.envConfigured
        } catch {
            // Silently ignore — fields remain editable if status check fails
        }
    }

    private func save() async {
        guard let client = manager.client else { return }

        if let t = Int(authSessionTimeout.trimmingCharacters(in: .whitespaces)), t < 15 || t > 1440 {
            errorMessage = "Session Timeout must be between 15 and 1440 minutes."
            return
        }

        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            // Settings are flat string key/values server-side; send a raw dict so we can
            // include keys (e.g. oidcGroupsClaim) the SDK's UpdateSettings doesn't model.
            var body: [String: String] = [
                "authLocalEnabled": String(authLocalEnabled),
                "authPasswordPolicy": authPasswordPolicy,
                "authSessionTimeout": authSessionTimeout,
                "oidcEnabled": String(oidcEnabled),
                "oidcMergeAccounts": String(oidcMergeAccounts),
                "oidcSkipTlsVerify": String(oidcSkipTlsVerify),
                "oidcAutoRedirectToProvider": String(oidcAutoRedirectToProvider),
            ]
            // Omit empty optional fields so they don't overwrite existing server values.
            func setIfPresent(_ key: String, _ value: String) {
                let trimmed = value.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { body[key] = trimmed }
            }
            setIfPresent("oidcClientId", oidcClientId)
            setIfPresent("oidcClientSecret", oidcClientSecret)
            setIfPresent("oidcIssuerUrl", oidcIssuerUrl)
            setIfPresent("oidcScopes", oidcScopes)
            setIfPresent("oidcGroupsClaim", oidcGroupsClaim)
            setIfPresent("oidcProviderName", oidcProviderName)
            setIfPresent("oidcProviderLogoUrl", oidcProviderLogoUrl)

            let path = client.rest.environmentPath(manager.activeEnvironmentID, "settings")
            let _: [PublicSetting] = try await client.rest.put(path, body: body)
            if let cached = manager.cached {
                await cached.invalidate(envID: manager.activeEnvironmentID, paths: [path, path + "*"])
            }
            showToast(.success("Authentication settings saved"))
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }
}
