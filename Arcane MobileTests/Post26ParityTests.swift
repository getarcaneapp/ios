import Arcane
import Testing

@testable import Arcane_Mobile

@MainActor
@Suite
struct Post26ParityTests {
    @Test
    func deployDraftResetsRecreateVolumesAfterEveryAttempt() {
        var draft = ProjectDeployOptionsDraft(
            pullPolicy: "always",
            forceRecreate: true,
            recreateVolumes: true
        )

        let first = draft.consume()
        let second = draft.consume()

        #expect(first.pullPolicy == "always")
        #expect(first.forceRecreate == true)
        #expect(first.recreateVolumes == true)
        #expect(second.recreateVolumes == false)
        #expect(!draft.recreateVolumes)
    }

    @Test
    func genericNotificationStateBuildsStructuredHeadersAndEvents() {
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
            Issue.record("Expected generic configuration")
            return
        }
        #expect(config.method == "PATCH")
        #expect(config.customHeaders?["X-Environment"] == "production")
        #expect(config.customHeaders?["X-Empty"] == "")
        #expect(config.payloadTemplate == #"{"title":"{{ title }}"}"#)
        #expect(config.successBodyContains == "accepted")
        #expect(config.events?.autoHeal == false)
    }

    @Test
    func structuredRowsKeepIdentityWhileValuesChange() {
        var row = StableStringRow(value: "first")
        let id = row.id
        row.value = "second"

        var header = StableHeaderRow(name: "X-First", value: "one")
        let headerID = header.id
        header.name = "X-Second"
        header.value = "two"

        #expect(row.id == id)
        #expect(header.id == headerID)
    }

    @Test
    func olderServersHideGoogleChatAndOmitRepositoryNames() {
        #expect(!notificationProviders(supportsPost26Features: false).contains(.googlechat))
        #expect(notificationProviders(supportsPost26Features: true).contains(.googlechat))

        let rows = [StableStringRow(value: " getarcaneapp/arcane ")]
        #expect(registryRepositoryNames(rows: rows, supported: false) == nil)
        #expect(
            registryRepositoryNames(rows: rows, supported: true)
                == ["getarcaneapp/arcane"]
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
            Issue.record("Expected generic configuration")
            return
        }
        #expect(legacyConfig.contentType == nil)
        #expect(legacyConfig.titleKey == nil)
        #expect(legacyConfig.messageKey == nil)
        #expect(legacyConfig.successBodyContains == nil)
        #expect(legacyConfig.payloadTemplate == nil)
        #expect(legacyConfig.customHeaders?["X-Environment"] == "production")
    }
}
