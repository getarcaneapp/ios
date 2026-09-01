import Arcane
import Testing

@testable import Arcane_Mobile

@Suite("Login capabilities")
struct LoginCapabilitiesTests {
    @Test
    func explicitServerSettingDisablesLocalAuthentication() {
        let capabilities = LoginCapabilities(publicSettings: [
            setting("authLocalEnabled", " false "),
            setting("oidcEnabled", "true"),
            setting("oidcProviderName", "Company SSO"),
        ])

        #expect(!capabilities.localAuthEnabled)
        #expect(capabilities.oidcEnabled)
        #expect(capabilities.oidcProviderName == "Company SSO")
    }

    @Test
    func missingLocalAuthenticationSettingKeepsOlderServersCompatible() {
        let capabilities = LoginCapabilities(publicSettings: [
            setting("oidcEnabled", "false")
        ])

        #expect(capabilities.localAuthEnabled)
        #expect(!capabilities.oidcEnabled)
    }

    private func setting(_ key: String, _ value: String) -> PublicSetting {
        PublicSetting(key: key, type: "string", value: value)
    }
}
