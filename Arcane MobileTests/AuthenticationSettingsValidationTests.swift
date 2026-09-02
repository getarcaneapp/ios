import Testing

@testable import Arcane_Mobile

@Suite("Authentication settings validation")
struct AuthenticationSettingsValidationTests {
    @Test
    func acceptsSupportedSessionTimeoutBoundaries() {
        #expect(AuthenticationSettingsValidation.sessionTimeoutError(for: "15") == nil)
        #expect(AuthenticationSettingsValidation.sessionTimeoutError(for: "525600") == nil)
    }

    @Test
    func rejectsSessionTimeoutsOutsideSupportedRange() {
        #expect(AuthenticationSettingsValidation.sessionTimeoutError(for: "14") != nil)
        #expect(AuthenticationSettingsValidation.sessionTimeoutError(for: "525601") != nil)
        #expect(AuthenticationSettingsValidation.sessionTimeoutError(for: "not a number") != nil)
    }
}
