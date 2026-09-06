import SwiftUI
import Arcane

struct SystemBackupsView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @State private var entries: [BackupHistoryEntry] = []
    @State private var errorMessage: String?
    @State private var busy = false
    @State private var hasMore = false
    @State private var search = ""
    @State private var supported = true
    @State private var showCreate = false
    @State private var showVolumeBackup = false
    @State private var showSettings = false
    private var canRead: Bool { manager.currentUser?.isAdmin == true && manager.permissions.has("system-backups:read", in: nil) }
    private var canManage: Bool { manager.currentUser?.isAdmin == true && manager.permissions.has("system-backups:manage", in: nil) }
    var body: some View {
        Group {
            if !canRead { ContentUnavailableView("Administrator Access Required", systemImage: "lock") }
            else {
                List {
                    if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                    Section("History") {
                        ForEach(entries) { entry in
                            NavigationLink { SystemBackupDetailView(entry: entry) } label: {
                                VStack(alignment: .leading) {
                                    Text(entry.resourceName)
                                    Text(entry.createdAt, style: .date)
                                    Text("\(entry.status) · \(entry.destination) · \(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if hasMore { Button("Load more") { Task { await load(more: true) } }.disabled(busy) }
                        if busy { ProgressView().frame(maxWidth: .infinity) }
                        if entries.isEmpty && !busy && errorMessage == nil {
                            ContentUnavailableView(
                                search.isEmpty ? "No Backups" : "No Matching Backups",
                                systemImage: "externaldrive.badge.timemachine",
                                description: Text(search.isEmpty ? "Create a backup using the toolbar." : "Try a different search.")
                            )
                            .listRowBackground(Color.clear)
                        }
                    }
                }
                .searchable(text: $search)
                .refreshable { await load() }
            }
        }
        .navigationTitle("Backups")
        .modifier(BackupSessionScope())
        .toolbar {
            if canRead && supported {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if canManage {
                            Button("Back Up Volumes", systemImage: "externaldrive.badge.plus") {
                                showVolumeBackup = true
                            }
                        }
                        Button("Backup Settings", systemImage: "gearshape") { showSettings = true }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Backup options")
                }
                if canManage {
                    if #available(iOS 26, *) {
                        ToolbarSpacer(.fixed, placement: .topBarTrailing)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Create Backup", systemImage: "plus") { showCreate = true }
                    }
                }
            }
        }
        .navigationDestination(isPresented: $showSettings) { BackupSettingsView() }
        .sheet(isPresented: $showCreate, onDismiss: { Task { await load() } }) {
            NavigationStack {
                SystemBackupCreateView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showCreate = false } }
                    }
            }
        }
        .sheet(isPresented: $showVolumeBackup, onDismiss: { Task { await load() } }) {
            NavigationStack {
                SystemVolumeRunView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showVolumeBackup = false } }
                    }
            }
        }
        .task(id: "\(manager.clientGeneration):\(search)") {
            await load()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                if entries.contains(where: { $0.status == "running" }) { await load() }
            }
        }
    }
    private func load(more: Bool = false) async {
        let scope = BackupRequestScope(manager)
        guard canRead, let client = manager.client else { return }
        busy = true; errorMessage = nil; defer { busy = false }
        if !more { entries = [] }
        do {
            let page = try await client.systemBackups.history(query: .init(search: search, start: entries.count, limit: 50, sortBy: "createdAt", sortOrder: .descending))
            try scope.check(manager); supported = true; entries += page.data; hasMore = entries.count < page.pagination.totalItems
        } catch is CancellationError {} catch ArcaneError.notFound { supported = false; errorMessage = "System backups are not available on this server." } catch is CancellationError {} catch { errorMessage = friendlyErrorMessage(error) }
    }
}

struct SystemBackupCreateView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.dismiss) private var dismiss
    var discover = false
    @State private var destination = "local"
    @State private var s3ID = ""
    @State private var recoveryKey = ""
    @State private var destinations: [S3Destination] = []
    @State private var busy = false
    @State private var errorMessage: String?
    var body: some View {
        Form {
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            if !discover {
                Picker("Storage", selection: $destination) {
                    Text("Local").tag("local"); Text("S3").tag("s3"); Text("Local and S3").tag("local_s3")
                }
            }
            if discover {
                Section {
                    BackupDestinationPicker(selection: $s3ID, destinations: destinations)
                } footer: {
                    Text("Searches for Arcane system backups in the selected destination's existing recovery repository. Choose the destination and path originally used for those backups.")
                }
            } else if destination != "local" {
                BackupDestinationPicker(selection: $s3ID, destinations: destinations)
            }
            Section {
                SecureField("Recovery key", text: $recoveryKey).privacySensitive().textInputAutocapitalization(.never).autocorrectionDisabled()
            } footer: { Text("Enter the recovery key for remote backups, or leave it empty to use the server's stored key.") }
        }
        .navigationTitle(discover ? "Discover System Backups" : "Create Backup")
        .modifier(BackupSessionScope())
        .disabled(busy)
        .toolbar { Button(discover ? "Discover" : "Create") { Task { await submit() } }.disabled(busy || ((discover || destination != "local") && s3ID.isEmpty)) }
        .task(id: manager.clientGeneration) {
            let scope = BackupRequestScope(manager)
            guard let client = manager.client, manager.permissions.has("s3-destinations:list", in: nil) else { return }
            do { let result = try await client.s3Destinations.options(); try scope.check(manager); destinations = result } catch is CancellationError {} catch { errorMessage = friendlyErrorMessage(error) }
        }
        .onDisappear { recoveryKey = "" }
    }
    private func submit() async {
        let scope = BackupRequestScope(manager)
        guard let client = manager.client else { return }
        busy = true; defer { busy = false }
        do {
            if discover {
                let count = try await client.systemBackups.discover(.init(s3DestinationId: s3ID, recoveryKey: recoveryKey))
                try scope.check(manager); showToast(.info("Found \(count) backups"))
            } else {
                _ = try await client.systemBackups.create(.init(destination: destination, s3DestinationId: destination == "local" ? nil : s3ID, recoveryKey: recoveryKey.isEmpty ? nil : recoveryKey))
                try scope.check(manager); showToast(.info("Backup started. Check history for completion."))
            }
            recoveryKey = ""; dismiss()
        } catch is CancellationError {} catch { errorMessage = friendlyErrorMessage(error) }
    }
}

struct BackupRecoveryKeyView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @State private var key = ""
    @State private var busy = false
    @State private var message: String?
    var body: some View {
        Form {
            SecureField("Recovery key", text: $key).privacySensitive().textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Generate key") { Task { await generate() } }
            if !key.isEmpty {
                Button("Copy recovery key") { UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: key]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(60)]); showToast(.copied("Recovery key copied")) }
                ShareLink("Export recovery key", item: key)
                Button("Save recovery key on server") { Task { await save() } }
            }
            if let message { Text(message) }
        }
        .navigationTitle("Recovery Key").disabled(busy)
        .modifier(BackupSessionScope())
        .onDisappear { key = "" }
    }
    private func generate() async {
        let scope = BackupRequestScope(manager)
        guard let client = manager.client else { return }
        busy = true; defer { busy = false }
        do { let generated = try await client.systemBackups.generateRecoveryKey(); try scope.check(manager); key = generated.recoveryKey; message = "Store this key somewhere safe before saving it on the server." }
        catch is CancellationError {} catch { message = friendlyErrorMessage(error) }
    }
    private func save() async {
        let scope = BackupRequestScope(manager)
        guard let client = manager.client else { return }
        busy = true; defer { busy = false }
        do { _ = try await client.systemBackups.setRecoveryKey(.init(recoveryKey: key)); key = ""; try scope.check(manager); showToast(.success("Recovery key saved")) }
        catch is CancellationError {} catch { message = friendlyErrorMessage(error) }
    }
}

struct SystemVolumeRunView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @State private var destination = "local"
    @State private var s3ID = ""
    @State private var stopContainers = false
    @State private var selectionMode = "all"
    @State private var ignoreAnonymous = true
    @State private var selected: Set<String> = []
    @State private var options: [SystemVolumeBackupOption] = []
    @State private var destinations: [S3Destination] = []
    @State private var busy = false
    @State private var errorMessage: String?
    var body: some View {
        Form {
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            Picker("Storage", selection: $destination) { Text("Local").tag("local"); Text("S3").tag("s3"); Text("Local and S3").tag("local_s3") }
            if destination != "local" { BackupDestinationPicker(selection: $s3ID, destinations: destinations) }
            Toggle("Stop containers during backup", isOn: $stopContainers)
            Toggle("Ignore anonymous volumes", isOn: $ignoreAnonymous)
            Picker("Volumes", selection: $selectionMode) { Text("All").tag("all"); Text("Only selected").tag("allowlist"); Text("Except selected").tag("blocklist") }
            if selectionMode != "all" {
                ForEach(options, id: \.name) { option in
                    Toggle(option.name, isOn: Binding(get: { selected.contains(option.name) }, set: { if $0 { selected.insert(option.name) } else { selected.remove(option.name) } })).disabled(!option.available)
                }
            }
        }
        .navigationTitle("Back Up Volumes").disabled(busy)
        .modifier(BackupSessionScope())
        .toolbar { Button("Run") { Task { await run() } }.disabled(busy || (destination != "local" && s3ID.isEmpty) || (selectionMode == "allowlist" && selected.isEmpty)) }
        .task(id: manager.clientGeneration) {
            let scope = BackupRequestScope(manager)
            guard let client = manager.client else { return }
            do {
                let result = try await client.systemBackups.volumeOptions()
                try scope.check(manager); options = result
                if manager.permissions.has("s3-destinations:list", in: nil) { let result = try await client.s3Destinations.options(); try scope.check(manager); destinations = result }
            } catch { errorMessage = friendlyErrorMessage(error) }
        }
    }
    private func run() async {
        let scope = BackupRequestScope(manager)
        guard let client = manager.client else { return }
        busy = true; defer { busy = false }
        do {
            _ = try await client.systemBackups.runVolumeBackups(.init(custom: .init(destination: destination, s3DestinationId: destination == "local" ? nil : s3ID, stopContainers: stopContainers, selectionMode: selectionMode, volumeNames: Array(selected), ignoreAnonymous: ignoreAnonymous)))
            try scope.check(manager); showToast(.info("Volume backups started. Check history for completion.")); dismiss()
        } catch is CancellationError {} catch { errorMessage = friendlyErrorMessage(error) }
    }
}
