import Arcane
import XCTest

@testable import Arcane_Mobile

final class Post26ParityTests: XCTestCase {
    func testDeployDraftResetsRecreateVolumesAfterEveryAttempt() {
        var draft = ProjectDeployOptionsDraft(
            pullPolicy: "always",
            forceRecreate: true,
            recreateVolumes: true
        )

        let first = draft.consume()
        let second = draft.consume()

        XCTAssertEqual(first.pullPolicy, "always")
        XCTAssertEqual(first.forceRecreate, true)
        XCTAssertEqual(first.recreateVolumes, true)
        XCTAssertEqual(second.recreateVolumes, false)
        XCTAssertFalse(draft.recreateVolumes)
    }

    func testGenericNotificationStateBuildsStructuredHeadersAndEvents() {
        var state = NotificationProviderFormState(provider: .generic, existing: nil)
        state.enabled = true
        state.webhookURL = "https://hooks.example.test/notify"
        state.method = "PATCH"
        state.headers = [
            NotificationHeaderRow(name: "X-Environment", value: "production"),
            NotificationHeaderRow(name: "X-Empty", value: "")
        ]
        state.payloadTemplate = #"{"title":"{{ title }}"}"#
        state.successBodyContains = "accepted"
        state.events.autoHeal = false

        guard case .generic(let config) = state.configuration(for: .generic) else {
            return XCTFail("Expected generic configuration")
        }
        XCTAssertEqual(config.method, "PATCH")
        XCTAssertEqual(config.customHeaders?["X-Environment"], "production")
        XCTAssertEqual(config.customHeaders?["X-Empty"], "")
        XCTAssertEqual(config.payloadTemplate, #"{"title":"{{ title }}"}"#)
        XCTAssertEqual(config.successBodyContains, "accepted")
        XCTAssertEqual(config.events?.autoHeal, false)
    }

    func testStructuredRowsKeepIdentityWhileValuesChange() {
        var row = StableStringRow(value: "first")
        let id = row.id
        row.value = "second"

        var header = StableHeaderRow(name: "X-First", value: "one")
        let headerID = header.id
        header.name = "X-Second"
        header.value = "two"

        XCTAssertEqual(row.id, id)
        XCTAssertEqual(header.id, headerID)
    }

    func testOlderServersHideGoogleChatAndOmitRepositoryNames() {
        XCTAssertFalse(notificationProviders(supportsPost26Features: false).contains(.googlechat))
        XCTAssertTrue(notificationProviders(supportsPost26Features: true).contains(.googlechat))

        let rows = [StableStringRow(value: " getarcaneapp/arcane ")]
        XCTAssertNil(registryRepositoryNames(rows: rows, supported: false))
        XCTAssertEqual(
            registryRepositoryNames(rows: rows, supported: true),
            ["getarcaneapp/arcane"]
        )

        var generic = NotificationProviderFormState(provider: .generic, existing: nil)
        generic.webhookURL = "https://hooks.example.test/notify"
        generic.contentType = "application/problem+json"
        generic.titleKey = "subject"
        generic.messageKey = "body"
        generic.successBodyContains = "accepted"
        generic.payloadTemplate = #"{"subject":"{{ title }}"}"#
        generic.headers = [NotificationHeaderRow(name: "X-Environment", value: "production")]

        guard case .generic(let legacyConfig) = generic.configuration(
            for: .generic,
            supportsPost26Features: false
        ) else {
            return XCTFail("Expected generic configuration")
        }
        XCTAssertNil(legacyConfig.contentType)
        XCTAssertNil(legacyConfig.titleKey)
        XCTAssertNil(legacyConfig.messageKey)
        XCTAssertNil(legacyConfig.successBodyContains)
        XCTAssertNil(legacyConfig.payloadTemplate)
        XCTAssertEqual(legacyConfig.customHeaders?["X-Environment"], "production")
    }
}
