import Arcane
import Foundation

struct BackupPolicyDraft: Identifiable {
    var id = UUID().uuidString
    var isNew = true
    var enabled = false
    var schedule = "0 0 2 * * *"
    var retentionCount = 7
    var stopContainers = false
    var localEnabled = true
    var s3Enabled = false
    var s3DestinationId = ""
    var selectionMode = "all"
    var volumeNames = ""
    var ignoreAnonymous = true

    var isValid: Bool {
        !schedule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && retentionCount >= 0 && retentionCount <= 3650
        && (localEnabled || s3Enabled) && (!s3Enabled || !s3DestinationId.isEmpty)
    }
    var update: UpdateBackupPolicy {
        .init(id: isNew ? nil : id, enabled: enabled, schedule: schedule, retentionCount: retentionCount,
              stopContainers: stopContainers, localEnabled: localEnabled, s3Enabled: s3Enabled,
              s3DestinationId: s3DestinationId.isEmpty ? nil : s3DestinationId)
    }
    var volumeUpdate: UpdateSystemVolumeBackupPolicy {
        .init(id: isNew ? nil : id, enabled: enabled, schedule: schedule, retentionCount: retentionCount,
              stopContainers: stopContainers, localEnabled: localEnabled, s3Enabled: s3Enabled,
              s3DestinationId: s3DestinationId.isEmpty ? nil : s3DestinationId, selectionMode: selectionMode,
              volumeNames: volumeNames.split(separator: "\n").map(String.init), ignoreAnonymous: ignoreAnonymous)
    }
}
