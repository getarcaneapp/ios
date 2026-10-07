import Foundation
import Testing
@testable import Arcane_Mobile

@Suite("Compose Preview preference")
struct ComposePreviewSessionTests {
    @Test func defaultsOffAndPersistsForNewSessions() throws {
        let suite = "compose-preview-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!ComposePreviewSession(defaults: defaults).isEnabled)
        defaults.set(true, forKey: ComposePreviewSession.preferenceKey)
        let reopened = try #require(UserDefaults(suiteName: suite))
        #expect(ComposePreviewSession(defaults: reopened).isEnabled)
    }

    @Test func changingPreferenceDoesNotChangeOpenSessions() throws {
        let suite = "compose-preview-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacySession = ComposePreviewSession(defaults: defaults)
        defaults.set(true, forKey: ComposePreviewSession.preferenceKey)
        let previewSession = ComposePreviewSession(defaults: defaults)
        defaults.set(false, forKey: ComposePreviewSession.preferenceKey)
        #expect(!legacySession.isEnabled)
        #expect(previewSession.isEnabled)
        #expect(!ComposePreviewSession(defaults: defaults).isEnabled)
    }
}
