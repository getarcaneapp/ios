import Foundation
import Testing

@testable import Arcane_Mobile

@Suite
struct GitOpsSyncDetailsTests {
    private static let deployJSON = """
        {
          "id": "6f1c2a9e-1b2c-4d3e-8f90-123456789abc",
          "name": "homelab-stack",
          "environmentId": "0",
          "repositoryId": "repo-1",
          "repository": {
            "id": "repo-1",
            "name": "homelab",
            "url": "git@github.com:acme/homelab.git",
            "authType": "ssh",
            "hasToken": false,
            "hasSshKey": true,
            "hasSigningKey": false,
            "enabled": true,
            "createdAt": "2026-09-15T20:18:46.987013Z",
            "updatedAt": "2026-09-15T20:18:46.987013Z"
          },
          "branch": "main",
          "composePath": "stacks/web/compose.yaml",
          "targetType": "project",
          "mode": "deploy",
          "projectName": "web",
          "projectId": "project-1",
          "autoSync": true,
          "syncInterval": 60,
          "syncDirectory": true,
          "pullImageAfterSync": false,
          "redeployAfterSync": true,
          "syncedFiles": "[\\"compose.yaml\\",\\".env\\"]",
          "maxSyncFiles": 500,
          "maxSyncTotalSize": 0,
          "maxSyncBinarySize": 0,
          "lastSyncAt": "2026-10-10T08:30:00Z",
          "lastSyncStatus": "failed",
          "lastSyncError": "authentication required",
          "lastSyncCommit": "0123456789abcdef0123456789abcdef01234567",
          "preDeployNetworkMode": "none",
          "preDeployTimeoutSec": 300,
          "backupOnSave": false,
          "backupPending": false,
          "createdAt": "2026-09-15T20:18:46.987013Z",
          "updatedAt": "2026-09-16T10:00:00Z"
        }
        """

    private static let backupJSON = """
        {
          "id": "sync-2",
          "name": "web backup",
          "environmentId": "0",
          "repositoryId": "repo-2",
          "branch": "backups",
          "composePath": "",
          "targetType": "project",
          "mode": "backup",
          "projectName": "web",
          "backupDirectory": "arcane/web",
          "backupPaths": ["config/", "nginx.conf"],
          "backupState": "needs_attention",
          "backupFailureReason": "conflict",
          "backupOnSave": true,
          "backupPending": true,
          "lastSyncError": "remote changed",
          "autoSync": false,
          "syncInterval": 0,
          "syncDirectory": false,
          "pullImageAfterSync": false,
          "redeployAfterSync": false,
          "maxSyncFiles": 0,
          "maxSyncTotalSize": 0,
          "maxSyncBinarySize": 0,
          "preDeployTimeoutSec": 0,
          "preDeployNetworkMode": "none",
          "createdAt": "2026-09-15T20:18:46Z",
          "updatedAt": "2026-09-15T20:18:46Z"
        }
        """

    private func decode(_ json: String) throws -> GitOpsSyncDetails {
        let resource = try JSONDecoder().decode(DynamicResource.self, from: Data(json.utf8))
        return GitOpsSyncDetails(resource: resource)
    }

    @Test
    func decodesDeploySync() throws {
        let sync = try decode(Self.deployJSON)

        #expect(sync.id == "6f1c2a9e-1b2c-4d3e-8f90-123456789abc")
        #expect(sync.name == "homelab-stack")
        #expect(!sync.isBackup)
        #expect(sync.repositoryName == "homelab")
        #expect(sync.branch == "main")
        #expect(sync.composePath == "stacks/web/compose.yaml")
        #expect(sync.projectID == "project-1")
        #expect(sync.autoSync)
        #expect(sync.syncIntervalDescription == "Every hour")
        #expect(sync.syncDirectory)
        #expect(sync.redeployAfterSync)
        #expect(sync.syncedFiles == ["compose.yaml", ".env"])
        #expect(sync.maxSyncFiles == 500)
        #expect(sync.shortCommit == "0123456")
        #expect(sync.statusPresentation == .init(status: "failed", label: "Failed"))
        #expect(sync.visibleError == "authentication required")
        let createdAt = try #require(sync.createdAt)
        #expect(abs(createdAt.timeIntervalSince1970 - 1_789_503_526.987) < 0.01)
        #expect(sync.lastSyncAt != nil)
        #expect(sync.repositoryWebURL?.absoluteString == "https://github.com/acme/homelab")
        #expect(
            sync.commitURL?.absoluteString
                == "https://github.com/acme/homelab/commit/0123456789abcdef0123456789abcdef01234567")
    }

    @Test
    func decodesBackupSync() throws {
        let sync = try decode(Self.backupJSON)

        #expect(sync.isBackup)
        #expect(sync.backupDirectory == "arcane/web")
        #expect(sync.backupPaths == ["config/", "nginx.conf"])
        #expect(sync.backupOnSave)
        #expect(sync.backupPending)
        #expect(sync.composePath == nil)
        #expect(sync.statusPresentation == .init(status: "error", label: "Needs Attention"))
        #expect(sync.backupFailureDescription == "Remote changes conflict")
        #expect(sync.visibleError == "remote changed")
        #expect(sync.lastBackupAt == nil)
        #expect(sync.repositoryWebURL == nil)
    }

    @Test
    func toleratesMissingFields() throws {
        let sync = try decode(#"{"id": "legacy", "name": "Legacy"}"#)

        #expect(sync.mode == .deploy)
        #expect(sync.backupState == "never")
        #expect(sync.statusPresentation.label == "Not Synced")
        #expect(sync.syncedFiles.isEmpty)
        #expect(sync.visibleError == nil)
    }

    @Test(arguments: [
        (5, "Every 5 minutes"), (1, "Every minute"), (120, "Every 2 hours"), (1440, "Every day"), (0, "Manual"),
    ])
    func formatsSyncInterval(minutes: Int, expected: String) {
        #expect(GitOpsSyncDetails.intervalDescription(minutes: minutes) == expected)
    }

    @Test
    func buildsRepositoryWebURLs() {
        #expect(
            GitOpsSyncDetails.webURL(forRepository: "https://gitlab.com/acme/app.git")?.absoluteString
                == "https://gitlab.com/acme/app")
        #expect(
            GitOpsSyncDetails.webURL(forRepository: "ssh://git@git.example.com:2222/acme/app.git")?.absoluteString
                == "https://git.example.com/acme/app")
        #expect(
            GitOpsSyncDetails.commitURL(repository: "https://gitlab.com/acme/app.git", commit: "abc123")?
                .absoluteString == "https://gitlab.com/acme/app/-/commit/abc123")
        #expect(GitOpsSyncDetails.webURL(forRepository: "") == nil)
    }
}
