import Testing
@testable import Arcane_Mobile

@Suite
struct ProjectDraftSnapshotTests {
    @Test func reviewIdentifiesServicesAndFieldsWithoutLeakingValues() {
        let old = ProjectDraftSnapshot(compose: "services:\n  web:\n    image: nginx\n    environment:\n      PASSWORD: old-secret\n  retired:\n    image: alpine\n", environment: "SECRET=before")
        let draft = ProjectDraftSnapshot(compose: "services:\n  worker:\n    image: alpine\n  web:\n    image: nginx:stable\n    environment:\n      PASSWORD: new-secret\n", environment: "SECRET=after")
        #expect(draft.serviceChanges(from: old) == ["Removed service: retired", "web: environment changed", "web: image changed", "Added service: worker"])
        #expect(!draft.serviceChanges(from: old).joined().contains("secret"))
    }

    @Test func noOpHasNoReviewChangesOrDiff() {
        let draft = ProjectDraftSnapshot(compose: "# 🐳\r\nservices:\r\n  web:\r\n    image: nginx # unchanged\r\n", environment: "SECRET=hidden")
        #expect(draft.serviceChanges(from: draft).isEmpty)
        #expect(draft.sourceDiff(from: draft).isEmpty)
    }

    @Test func diffContainsRemovedAndInsertedLinesOnly() {
        let old = ProjectDraftSnapshot(compose: "services:\n  web:\n    image: nginx\n# keep\n", environment: "")
        let draft = ProjectDraftSnapshot(compose: "services:\n  web:\n    image: nginx:stable\n# keep\n", environment: "")
        #expect(draft.sourceDiff(from: old) == "-     image: nginx\n+     image: nginx:stable")
        #expect(!draft.sourceDiff(from: old).contains("# keep"))
    }

    @Test func commentOnlyChangeDoesNotClaimServiceMutation() {
        let old = ProjectDraftSnapshot(compose: "# first\nservices:\n  web:\n    image: nginx\n", environment: "")
        let draft = ProjectDraftSnapshot(compose: old.compose.replacingOccurrences(of: "# first", with: "# second"), environment: "")
        #expect(draft.serviceChanges(from: old).isEmpty)
        #expect(draft.sourceDiff(from: old) == "- # first\n+ # second")
    }

    @Test func invalidRawYAMLIsRejectedBeforeSaving() {
        let malformed = ProjectDraftSnapshot(compose: "services: [unterminated", environment: "")
        #expect(throws: (any Error).self) { try malformed.validateSyntax() }
        #expect(malformed.serviceChanges(from: .init(compose: "", environment: "")).isEmpty)
    }

    @Test func validAdvancedYAMLRemainsSaveable() throws {
        let advanced = ProjectDraftSnapshot(compose: "x-common: &common\n  restart: always\nservices:\n  web:\n    <<: *common\n    image: ${IMAGE:-nginx}\n---\nmetadata: !custom value\n", environment: "")
        try advanced.validateSyntax()
    }

    @Test func asyncDefaultsNeverReplaceEditedOrDifferentSessionDrafts() {
        let original = ProjectDraftSnapshot(compose: "services: {}", environment: "")
        let composeEdit = ProjectDraftSnapshot(compose: "services:\n  web:\n    image: nginx", environment: "")
        let envEdit = ProjectDraftSnapshot(compose: original.compose, environment: "TOKEN=keep")
        #expect(original.canApplyLoadedContent(requestedFrom: original, session: "A", currentSession: "A"))
        #expect(!original.canApplyLoadedContent(requestedFrom: original, session: "A", currentSession: "B"))
        #expect(!composeEdit.canApplyLoadedContent(requestedFrom: original, session: "A", currentSession: "A"))
        #expect(!envEdit.canApplyLoadedContent(requestedFrom: original, session: "A", currentSession: "A"))
        #expect(composeEdit != original)
        #expect(envEdit != original)
    }
}
