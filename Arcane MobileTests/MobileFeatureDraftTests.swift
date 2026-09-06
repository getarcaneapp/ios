import Foundation
import Testing
import Arcane
@testable import Arcane_Mobile

@MainActor
@Suite struct MobileFeatureDraftTests {
    @Test func workspaceConflictReviewKeepsDraft() {
        var draft = VolumeWorkspaceDraft()
        draft.load("original")
        draft.text = "my changes"
        draft.conflict = true
        draft.review(latest: "server changes")
        #expect(draft.text == "my changes")
        #expect(draft.baseline == "server changes")
        #expect(draft.hasChanges)
        #expect(!draft.conflict)
    }

    @Test(arguments: ["../secret", "/absolute", "a//b", "a/./b", "a/../b", ""])
    func invalidWorkspacePaths(path: String) {
        #expect(!VolumeWorkspaceDraft.validRelativePath(path))
    }

    @Test func credentialsValidateAndClearGlobalScope() {
        var form = FederatedCredentialForm()
        #expect(form.validationMessage != nil)
        form.name = "CI"
        form.issuerUrl = "https://issuer.example"
        form.audiences = "arcane\ncli"
        form.subjectMatch = "repo:org/repo:*"
        form.roleId = "role"
        #expect(form.validationMessage == nil)
        #expect(form.updateRequest.environmentId == "")
        form.enabled = false
        #expect(form.updateRequest.enabled == false)
        form.tokenTtlSeconds = 59
        #expect(form.validationMessage != nil)
    }
    @Test func backupServerErrorsKeepTheirMessage() {
        let message = "No repository config file found for the selected S3 destination."
        let error = ArcaneError.server(code: "BAD_REQUEST", message: message)
        #expect(friendlyErrorMessage(error) == message)
        #expect(!friendlyErrorMessage(error).contains("ArcaneError"))
    }

}
