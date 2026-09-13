import SwiftUI
import Arcane
import UniformTypeIdentifiers

struct VolumeBackupsView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    let environmentID: EnvironmentID
    let volumeName: String
    @State private var loadMoreError: String?
    @State private var backups: [BackupEntry] = []
    @State private var warnings: [String] = []
    @State private var destinations: [S3Destination] = []
    @State private var destination = "local"
    @State private var s3ID = ""
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var hasMore = false
    @State private var showCreate = false
    @State private var supportsPolicies = false
    @State private var showImport = false
    @State private var importURL: URL?
    @State private var restoreTarget: BackupEntry?
    @State private var deleteTarget: BackupEntry?
    @State private var downloadURL: URL?

    private var canBackup: Bool { manager.permissions.has("volumes:backup", in: environmentID) }
    private var canUpload: Bool { manager.permissions.has("volumes:upload", in: environmentID) }

    var body: some View {
        List {
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            ForEach(warnings, id: \.self) { Text($0).foregroundStyle(.orange) }
            if canBackup {
                Section {
                    Button("Create backup") { showCreate = true }
                    if supportsPolicies { NavigationLink("Backup policies") { BackupPolicyEditor(environmentID: environmentID, volumeName: volumeName) } }
                    if canUpload { Button("Import and restore archive") { showImport = true } }
                }
            }
            if let downloadURL { ShareLink("Share downloaded backup", item: downloadURL) }
            ForEach(backups) { backup in
                Section {
                    LabeledContent(backup.createdAt, value: ByteCountFormatter.string(fromByteCount: backup.size, countStyle: .file))
                    if let status = backup.status { LabeledContent("Status", value: status) }
                    if let destination = backup.destination { LabeledContent("Storage", value: destination) }
                    if let name = backup.s3DestinationName { LabeledContent("S3 destination", value: name) }
                    if let error = backup.error { Text(error).foregroundStyle(.red) }
                    if backup.status == nil || backup.status == "succeeded" {
                        NavigationLink("Browse files") {
                            BackupFilesView(backupID: backup.id, environmentID: environmentID, volumeName: volumeName, canRestore: canBackup)
                        }
                        Button("Download archive") { Task { await download(backup) } }
                        if canBackup {
                            Button("Restore volume", role: .destructive) { restoreTarget = backup }
                            Menu("Upload to S3") {
                                ForEach(destinations) { destination in
                                    Button(destination.name) { Task { await upload(backup, to: destination.id) } }
                                }
                            }.disabled(destinations.isEmpty)
                        }
                    }
                    if canBackup { Button("Delete backup", role: .destructive) { deleteTarget = backup } }
                }
            }
            PaginatedListFooter(
                hasMore: hasMore, loadMoreError: loadMoreError,
                onRetry: { Task { await load(more: true) } },
                onLoadMore: { Task { await load(more: true) } }
            )
            if busy { ProgressView() }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Backups")
        .modifier(BackupSessionScope())
        .disabled(busy)
        .task(id: "\(manager.clientGeneration):\(environmentID.rawValue):\(volumeName)") {
            await load()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                if backups.contains(where: { $0.status == "running" }) { await load() }
            }
        }
        .refreshable { await load() }
        .sheet(isPresented: $showCreate) {
            NavigationStack {
                Form {
                    Picker("Storage", selection: $destination) {
                        Text("Local").tag("local")
                        if supportsPolicies { Text("S3").tag("s3"); Text("Local and S3").tag("local_s3") }
                    }
                    if destination != "local" { BackupDestinationPicker(selection: $s3ID, destinations: destinations) }
                }
                .navigationTitle("Create Backup")
        .modifier(BackupSessionScope())
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showCreate = false } }
                    ToolbarItem(placement: .confirmationAction) { Button("Create") { Task { await create() } }.disabled(destination != "local" && s3ID.isEmpty) }
                }
            }
        }
        .fileImporter(isPresented: $showImport, allowedContentTypes: [.data]) { result in
            switch result { case .success(let url): importURL = url; case .failure(let error): showToast(.error(friendlyErrorMessage(error))) }
        }
        .confirmationDialog("Restore backup to \(volumeName)?", isPresented: Binding(get: { restoreTarget != nil }, set: { if !$0 { restoreTarget = nil } }), titleVisibility: .visible) {
            Button("Restore volume", role: .destructive) { if let backup = restoreTarget { Task { await restore(backup) } } }
        } message: { Text("Existing volume contents may be overwritten.") }
        .confirmationDialog("Delete this backup?", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }), titleVisibility: .visible) {
            Button("Delete backup", role: .destructive) { if let backup = deleteTarget { Task { await remove(backup) } } }
        }
        .confirmationDialog("Import archive and restore to \(volumeName)?", isPresented: Binding(get: { importURL != nil }, set: { if !$0 { importURL = nil } }), titleVisibility: .visible) {
            Button("Import and restore", role: .destructive) { if let url = importURL { Task { await importBackup(url) } } }
        } message: { Text("Choose a tar.gz volume backup. Existing volume contents may be overwritten.") }
        .onDisappear { if let downloadURL { try? FileManager.default.removeItem(at: downloadURL) } }
    }

    private func load(more: Bool = false) async {
        guard !busy else { return }
        loadMoreError = nil
        let scope = BackupRequestScope(manager)
        guard let client = manager.client else { return }
        busy = true; errorMessage = nil
        defer { busy = false }
        do {
            let page = try await client.volumes.listBackupsWithWarnings(envID: environmentID, name: volumeName, query: .init(start: more ? backups.count : 0, limit: 50))
            try scope.check(manager)
            backups = more ? backups + page.data : page.data; warnings = page.warnings ?? []; hasMore = backups.count < page.pagination.totalItems
            if !more {
                do {
                    _ = try await client.volumes.backupPolicies(envID: environmentID, name: volumeName)
                    try scope.check(manager); supportsPolicies = true
                } catch ArcaneError.notFound { supportsPolicies = false; destination = "local" }
                catch ArcaneError.forbidden { supportsPolicies = false }
                if supportsPolicies && manager.permissions.has("s3-destinations:list", in: nil) {
                    let options = try await client.s3Destinations.options()
                    try scope.check(manager); destinations = options
                }
            }
        } catch is CancellationError {} catch { if more { loadMoreError = friendlyErrorMessage(error) } else { errorMessage = friendlyErrorMessage(error) } }
    }

    private func create() async {
        let scope = BackupRequestScope(manager)
        guard let client = manager.client, canBackup else { return }
        await perform {
            _ = try await client.volumes.createBackup(envID: environmentID, name: volumeName, request: .init(destination: destination, s3DestinationId: destination == "local" ? nil : s3ID))
            showCreate = false
        }
    }
    private func restore(_ backup: BackupEntry) async {
        let scope = BackupRequestScope(manager)
        guard let client = manager.client, canBackup else { return }
        await perform { _ = try await client.volumes.restoreBackup(envID: environmentID, name: volumeName, backupID: backup.id) }
    }
    private func remove(_ backup: BackupEntry) async {
        let scope = BackupRequestScope(manager)
        guard let client = manager.client, canBackup else { return }
        await perform { _ = try await client.volumes.deleteBackup(envID: environmentID, backupID: backup.id) }
    }
    private func upload(_ backup: BackupEntry, to destinationID: String) async {
        let scope = BackupRequestScope(manager)
        guard let client = manager.client, canBackup else { return }
        await perform { _ = try await client.volumes.uploadBackupToS3(envID: environmentID, backupID: backup.id, s3DestinationID: destinationID) }
    }
    private func download(_ backup: BackupEntry) async {
        let scope = BackupRequestScope(manager)
        guard let client = manager.client else { return }
        busy = true; defer { busy = false }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).tar.gz")
        do {
            try await client.volumes.downloadBackup(envID: environmentID, backupID: backup.id, to: url)
            try scope.check(manager)
            if let old = downloadURL { try? FileManager.default.removeItem(at: old) }; downloadURL = url
        } catch is CancellationError { try? FileManager.default.removeItem(at: url) } catch { try? FileManager.default.removeItem(at: url); showToast(.error(friendlyErrorMessage(error))) }
    }
    private func importBackup(_ url: URL) async {
        let scope = BackupRequestScope(manager)
        guard let client = manager.client, canUpload else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() }; importURL = nil }
        await perform {
            let generation = manager.clientGeneration
            if manager.serverCapabilities?.supportsRoleManagement == true {
                let id = try await client.uploads.uploadFile(envID: environmentID, kind: .volumeBackup, fileURL: url)
                try scope.check(manager)
                guard manager.clientGeneration == generation, manager.activeEnvironmentID == environmentID else { throw CancellationError() }
                _ = try await client.volumes.uploadAndRestoreBackup(envID: environmentID, name: volumeName, uploadID: id)
            } else {
                _ = try await client.volumes.uploadAndRestoreBackup(envID: environmentID, name: volumeName, fileURL: url)
            }
        }
    }
    private func perform(_ operation: () async throws -> Void) async {
        let scope = BackupRequestScope(manager)
        busy = true
        do { try await operation(); try scope.check(manager); showToast(.info("Backup operation accepted")); await load() }
        catch is CancellationError {} catch { showToast(.error(friendlyErrorMessage(error))) }
        busy = false
    }
}
