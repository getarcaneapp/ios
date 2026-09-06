import SwiftUI
import Arcane

struct BackupPolicyEditor: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.dismiss) private var dismiss
    var environmentID: EnvironmentID? = nil
    var volumeName: String? = nil
    var systemVolumes = false
    @State private var policies: [BackupPolicyDraft] = []
    @State private var destinations: [S3Destination] = []
    @State private var loaded = false
    @State private var busy = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red) } }
            ForEach($policies) { $policy in
                Section("Policy") {
                    Toggle("Enabled", isOn: $policy.enabled)
                    TextField("Cron schedule", text: $policy.schedule).textInputAutocapitalization(.never)
                    Stepper("Keep \(policy.retentionCount) backups", value: $policy.retentionCount, in: 0...3650)
                    Toggle("Local storage", isOn: $policy.localEnabled)
                    Toggle("S3 storage", isOn: $policy.s3Enabled)
                    if policy.s3Enabled { BackupDestinationPicker(selection: $policy.s3DestinationId, destinations: destinations) }
                    if volumeName != nil || systemVolumes { Toggle("Stop containers during backup", isOn: $policy.stopContainers) }
                    if systemVolumes {
                        Picker("Volumes", selection: $policy.selectionMode) {
                            Text("All").tag("all"); Text("Only listed").tag("allowlist"); Text("Except listed").tag("blocklist")
                        }
                        if policy.selectionMode != "all" { TextField("Volume names, one per line", text: $policy.volumeNames, axis: .vertical) }
                        Toggle("Ignore anonymous volumes", isOn: $policy.ignoreAnonymous)
                    }
                    Button("Remove policy", role: .destructive) { policies.removeAll { $0.id == policy.id } }
                }
            }
            if loaded { Button("Add policy") { policies.append(.init()) } }
        }
        .navigationTitle("Backup Policies")
        .modifier(BackupSessionScope())
        .toolbar { ToolbarItem(placement: .confirmationAction) {
            Button("Save") { Task { await save() } }.disabled(!loaded || busy || !policies.allSatisfy(\.isValid))
        } }
        .disabled(busy)
        .task(id: manager.clientGeneration) { await load() }
    }

    private func load() async {
        let scope = BackupRequestScope(manager)
        guard let client = manager.client else { return }
        loaded = false; policies = []; errorMessage = nil
        do {
            if let name = volumeName {
                let result = try await client.volumes.backupPolicies(envID: environmentID, name: name)
                try scope.check(manager)
                policies = result.policies.map { p in
                    .init(id: p.id, isNew: false, enabled: p.enabled, schedule: p.schedule, retentionCount: p.retentionCount,
                          stopContainers: p.stopContainers, localEnabled: p.localEnabled, s3Enabled: p.s3Enabled, s3DestinationId: p.s3DestinationId ?? "")
                }
            } else if systemVolumes {
                let result = try await client.systemBackups.volumePolicies()
                try scope.check(manager)
                policies = result.policies.map { p in
                    .init(id: p.id, isNew: false, enabled: p.enabled, schedule: p.schedule, retentionCount: p.retentionCount,
                          stopContainers: p.stopContainers, localEnabled: p.localEnabled, s3Enabled: p.s3Enabled,
                          s3DestinationId: p.s3DestinationId ?? "", selectionMode: p.selectionMode,
                          volumeNames: p.volumeNames.joined(separator: "\n"), ignoreAnonymous: p.ignoreAnonymous)
                }
            } else {
                let result = try await client.systemBackups.policies()
                try scope.check(manager)
                policies = result.policies.map { p in
                    .init(id: p.id, isNew: false, enabled: p.enabled, schedule: p.schedule, retentionCount: p.retentionCount,
                          localEnabled: p.localEnabled, s3Enabled: p.s3Enabled, s3DestinationId: p.s3DestinationId ?? "")
                }
            }
            if manager.permissions.has("s3-destinations:list", in: nil) {
                let options = try await client.s3Destinations.options()
                try scope.check(manager); destinations = options
            }
            try scope.check(manager); loaded = true
        } catch is CancellationError {} catch { errorMessage = friendlyErrorMessage(error) }
    }

    private func save() async {
        let scope = BackupRequestScope(manager)
        guard let client = manager.client else { return }
        busy = true; defer { busy = false }
        do {
            if let name = volumeName {
                _ = try await client.volumes.updateBackupPolicies(envID: environmentID, name: name, request: .init(policies: policies.map(\.update)))
            } else if systemVolumes {
                _ = try await client.systemBackups.updateVolumePolicies(.init(policies: policies.map(\.volumeUpdate)))
            } else {
                _ = try await client.systemBackups.updatePolicies(.init(policies: policies.map(\.update)))
            }
            try scope.check(manager); showToast(.success("Backup policies saved")); dismiss()
        } catch is CancellationError {} catch { errorMessage = friendlyErrorMessage(error) }
    }
}

struct BackupDestinationPicker: View {
    @Binding var selection: String
    let destinations: [S3Destination]
    var body: some View {
        Picker("S3 destination", selection: $selection) {
            Text("Select destination").tag("")
            ForEach(destinations) { destination in Text(destination.name).tag(destination.id) }
            if !selection.isEmpty && !destinations.contains(where: { $0.id == selection }) { Text(selection).tag(selection) }
        }
    }
}
