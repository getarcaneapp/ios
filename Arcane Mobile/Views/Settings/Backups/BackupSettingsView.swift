import SwiftUI
import Arcane

struct BackupSettingsView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager

    private var canManage: Bool {
        manager.currentUser?.isGlobalAdmin == true
            && manager.permissions.has("system-backups:manage", in: nil)
    }

    var body: some View {
        Form {
            if canManage {
                Section("Schedules") {
                    NavigationLink {
                        BackupPolicyEditor()
                    } label: {
                        Label("System Backup Policies", systemImage: "calendar")
                    }
                    NavigationLink {
                        BackupPolicyEditor(systemVolumes: true)
                    } label: {
                        Label("Volume Backup Policies", systemImage: "externaldrive")
                    }
                }
            }
            if manager.permissions.has("s3-destinations:list", in: nil) {
                Section("Storage") {
                    NavigationLink {
                        S3DestinationsView()
                    } label: {
                        Label("S3 Destinations", systemImage: "externaldrive.connected.to.line.below")
                    }
                }
            }
            if canManage || manager.permissions.has("system-backups:recovery-key", in: nil) {
                Section("Recovery") {
                    if manager.permissions.has("system-backups:recovery-key", in: nil) {
                        NavigationLink { BackupRecoveryKeyView() } label: { Label("Recovery Key", systemImage: "key") }
                    }
                    if canManage {
                        NavigationLink {
                            SystemBackupCreateView(discover: true)
                        } label: {
                            Label("Discover Backups in S3", systemImage: "magnifyingglass")
                        }
                    }
                }
            }
        }
        .navigationTitle("Backup Settings")
        .modifier(BackupSessionScope())
    }
}
