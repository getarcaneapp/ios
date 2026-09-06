import Foundation
import Testing
@testable import Arcane_Mobile

@MainActor
@Suite struct BackupPolicyDraftTests {
    @Test func newPolicyOmitsServerID() throws {
        let draft = BackupPolicyDraft()
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(draft.update)) as? [String: Any])
        #expect(json["id"] == nil)
    }
    @Test func existingPolicyRetainsIDAndExplicitDestinationClearing() {
        let draft = BackupPolicyDraft(id: "existing", isNew: false, s3Enabled: false, s3DestinationId: "")
        #expect(draft.update.id == "existing")
        #expect(draft.update.s3Enabled == false)
        #expect(draft.update.s3DestinationId == nil)
    }
    @Test func retentionAndDestinationValidationMatchesServerLimits() {
        var draft = BackupPolicyDraft()
        draft.retentionCount = 0
        #expect(draft.isValid)
        draft.retentionCount = 3651
        #expect(!draft.isValid)
        draft.retentionCount = 7; draft.localEnabled = false
        #expect(!draft.isValid)
        draft.s3Enabled = true
        #expect(!draft.isValid)
        draft.s3DestinationId = "destination"
        #expect(draft.isValid)
    }
}
