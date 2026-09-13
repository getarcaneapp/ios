import SwiftUI
import Arcane

struct SystemBackupDetailView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let entry: BackupHistoryEntry
    @State private var recoveryKey = ""
    @State private var destinations: [S3Destination] = []
    @State private var destinationID = ""
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var pending: BackupOperation?
    private var isVolume: Bool { entry.resourceType == "volume" }
    private var canRestore: Bool { manager.permissions.has("system-backups:restore", in: nil) && (!isVolume || manager.permissions.has("volumes:backup", in: EnvironmentID(rawValue: "0"))) }
    private var canManage: Bool { manager.permissions.has("system-backups:manage", in: nil) && (!isVolume || manager.permissions.has("volumes:backup", in: EnvironmentID(rawValue: "0"))) }
    var body: some View {
        List {
            Section("Backup") {
                LabeledContent("Resource", value: entry.resourceName)
                LabeledContent("Status", value: entry.status)
                LabeledContent("Storage", value: entry.destination)
                LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                if let error = entry.error { Text(error).foregroundStyle(.red) }
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            if !isVolume {
                Section { FormSecureField(title: "Recovery key", placeholder: "", text: $recoveryKey).privacySensitive().textInputAutocapitalization(.never).autocorrectionDisabled() }
                footer: { Text("Leave empty to use the server's configured key.") }
            }
            if entry.status == "succeeded" {
                NavigationLink(isVolume ? "Browse volume files" : "Browse project files") {
                    BackupFilesView(backupID: entry.id, environmentID: isVolume ? EnvironmentID(rawValue: "0") : nil, volumeName: isVolume ? entry.resourceName : nil, recoveryKey: recoveryKey, canRestore: canRestore)
                }
                if canRestore { Button(isVolume ? "Restore volume" : "Restore server", role: .destructive) { pending = .restore } }
                if canManage {
                    Section("Upload to S3") {
                        BackupDestinationPicker(selection: $destinationID, destinations: destinations)
                        Button("Upload") { Task { await upload() } }.disabled(destinationID.isEmpty)
                    }
                }
            }
            if canManage { Button("Delete backup", role: .destructive) { pending = .delete } }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Backup Details").disabled(busy)
        .modifier(BackupSessionScope())
        .task(id: manager.clientGeneration) {
            let scope = BackupRequestScope(manager)
            guard let client = manager.client, manager.permissions.has("s3-destinations:list", in: nil) else { return }
            do { let result = try await client.s3Destinations.options(); try scope.check(manager); destinations = result } catch is CancellationError {} catch { errorMessage = friendlyErrorMessage(error) }
        }
        .confirmationDialog(pending == .restore ? "Restore \(entry.resourceName)?" : "Delete backup?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            Button(pending == .restore ? "Restore" : "Delete", role: .destructive) {
                if let operation = pending { Task { await perform(operation) } }
            }
        } message: { Text(pending == .restore ? "This replaces existing data. A server restore may disconnect the app. Reconnect and check server state before attempting another restore." : "This removes the stored backup.") }
        .onDisappear { recoveryKey = "" }
    }
    private func upload() async {
        let scope = BackupRequestScope(manager)
        guard let client = manager.client else { return }
        busy = true; defer { busy = false }
        do {
            if isVolume {
                _ = try await client.volumes.uploadBackupToS3(envID: EnvironmentID(rawValue: "0"), backupID: entry.id, s3DestinationID: destinationID)
            } else {
                _ = try await client.systemBackups.upload(id: entry.id, request: .init(s3DestinationId: destinationID, recoveryKey: recoveryKey))
            }
            try scope.check(manager); showToast(.info("Backup upload accepted"))
        } catch is CancellationError {} catch { errorMessage = friendlyErrorMessage(error) }
    }
    private func perform(_ operation: BackupOperation) async {
        let scope = BackupRequestScope(manager)
        guard let client = manager.client else { return }
        busy = true; defer { busy = false }
        do {
            switch operation {
            case .restore:
                if isVolume {
                    _ = try await client.volumes.restoreBackup(envID: EnvironmentID(rawValue: "0"), name: entry.resourceName, backupID: entry.id)
                } else {
                    _ = try await client.systemBackups.restore(id: entry.id, request: .init(recoveryKey: recoveryKey))
                }
                try scope.check(manager); showToast(.info("Restore request accepted. Refresh server state before further changes."))
            case .delete:
                if isVolume { _ = try await client.volumes.deleteBackup(envID: EnvironmentID(rawValue: "0"), backupID: entry.id) }
                else { _ = try await client.systemBackups.delete(id: entry.id, recoveryKey: recoveryKey.isEmpty ? nil : recoveryKey) }
                try scope.check(manager); showToast(.info("Backup deletion accepted"))
            }
            recoveryKey = ""; dismiss()
        } catch is CancellationError {} catch { errorMessage = operation == .restore ? "Restore response unavailable: \(friendlyErrorMessage(error)). Reconnect and verify server state before retrying." : friendlyErrorMessage(error) }
    }
}
