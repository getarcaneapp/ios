import SwiftUI
import Arcane

struct BackupFilesView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    let backupID: String
    var environmentID: EnvironmentID? = nil
    var volumeName: String? = nil
    var recoveryKey = ""
    var canRestore = false
    @State private var loadedIdentity = ""
    @State private var loadingIdentity: String?
    @State private var requestID = UUID()
    @State private var loadMoreError: String?
    private var listIdentity: String { "\(manager.clientGeneration):\(path):\(search)" }
    @State private var path = ""
    @State private var search = ""
    @State private var entries: [BackupFileEntry] = []
    @State private var selected: Set<String> = []
    @State private var selectAll = false
    @State private var legacyBrowser = false
    @State private var hasMore = false
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var confirm = false

    var body: some View {
        List {
            if busy && entries.isEmpty { ProgressView("Loading…").frame(maxWidth: .infinity) }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
                Button("Retry") { Task { await load() } }
            }
            Section {
                LabeledContent("Folder", value: path.isEmpty ? "/" : path)
                if !path.isEmpty { Button("Parent folder") { path = (path as NSString).deletingLastPathComponent } }
                if canRestore && !legacyBrowser { Toggle("Restore all matching files", isOn: $selectAll) }
            }
            ForEach(entries, id: \.path) { entry in
                HStack {
                    if canRestore && !selectAll {
                        Button { if !selected.insert(entry.path).inserted { selected.remove(entry.path) } } label: {
                            Image(systemName: selected.contains(entry.path) ? "checkmark.circle.fill" : "circle")
                        }.buttonStyle(.borderless).accessibilityLabel("Select \(entry.name)")
                    }
                    if entry.isDirectory {
                        Button { path = entry.path } label: { Label(entry.name, systemImage: "folder") }
                    } else { Label(entry.name, systemImage: "doc") }
                }
            }
            if entries.isEmpty && !busy && errorMessage == nil {
                ContentUnavailableView("No Files", systemImage: "folder", description: Text("Try another folder or search."))
            }
            PaginatedListFooter(
                hasMore: hasMore, loadMoreError: loadMoreError,
                onRetry: { Task { await load(more: true) } },
                onLoadMore: { Task { await load(more: true) } }
            ).id(entries.count)
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Backup Files")
        .modifier(BackupSessionScope())
        .searchable(text: $search)
        .task(id: "\(manager.clientGeneration):\(path):\(search)") { await load() }
        .toolbar { if canRestore { ToolbarItem(placement: .topBarTrailing) { Button("Restore") { confirm = true }.disabled(busy || (!selectAll && selected.isEmpty)) } } }
        .confirmationDialog("Restore files to \(volumeName ?? "the server projects directory")?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Restore \(selectAll ? "all matching files" : String(selected.count) + " selected paths")", role: .destructive) { Task { await restore() } }
        } message: { Text("Existing files at the selected paths may be overwritten.") }
    }

    private func load(more: Bool = false) async {
        let scope = BackupRequestScope(manager)
        guard let client = manager.client else { return }
        let key = listIdentity
        guard loadingIdentity != key else { return }
        let request = UUID()
        requestID = request
        loadingIdentity = key
        if loadedIdentity != key { entries = []; hasMore = false; loadedIdentity = key }
        busy = true; errorMessage = nil; loadMoreError = nil
        if !more { selected = []; selectAll = false }
        defer { if requestID == request { busy = false; loadingIdentity = nil } }
        do {
            let page: PaginatedResponse<BackupFileEntry>
            if volumeName != nil {
                do {
                    page = try await client.volumes.browseBackupFiles(envID: environmentID, backupID: backupID, path: path, search: search, start: more ? entries.count : 0, limit: 50)
                } catch ArcaneError.notFound {
                    let paths = try await client.volumes.listBackupFiles(envID: environmentID, backupID: backupID)
                    try scope.check(manager)
                    guard key == listIdentity, requestID == request else { return }
                    entries = paths.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }.map {
                        BackupFileEntry(path: $0, name: ($0 as NSString).lastPathComponent, isDirectory: false)
                    }
                    legacyBrowser = true; selectAll = false; hasMore = false
                    return
                }
            } else {
                page = try await client.systemBackups.browseFiles(id: backupID, recoveryKey: recoveryKey, path: path, search: search, start: more ? entries.count : 0, limit: 50)
            }
            try scope.check(manager)
            guard key == listIdentity, requestID == request else { return }
            if !more { entries = [] }
            entries += page.data
            hasMore = entries.count < page.pagination.totalItems
        } catch is CancellationError {} catch {
            guard key == listIdentity, requestID == request else { return }
            if more { loadMoreError = friendlyErrorMessage(error) }
            else { errorMessage = friendlyErrorMessage(error) }
        }
    }

    private func restore() async {
        let scope = BackupRequestScope(manager)
        guard let client = manager.client else { return }
        busy = true; defer { busy = false }
        do {
            if let volumeName {
                _ = try await client.volumes.restoreBackupFiles(envID: environmentID, name: volumeName, backupID: backupID,
                    selection: .init(paths: Array(selected), selectAll: selectAll, search: search.isEmpty ? nil : search))
            } else {
                _ = try await client.systemBackups.restoreFiles(id: backupID,
                    request: .init(paths: Array(selected), selectAll: selectAll, search: search.isEmpty ? nil : search, recoveryKey: recoveryKey))
            }
            try scope.check(manager); showToast(.info("Restore request accepted"))
        } catch is CancellationError {} catch { errorMessage = friendlyErrorMessage(error) }
    }
}
