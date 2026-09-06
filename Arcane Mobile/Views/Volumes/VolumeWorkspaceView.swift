import SwiftUI
import UniformTypeIdentifiers
import Arcane

struct VolumeWorkspaceView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    let environmentID: EnvironmentID
    let volumeName: String
    @State private var workspace: VolumeWorkspace?
    @State private var directory = ""
    @State private var selectedFile: ProjectFile?
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var unsupported = false
    @State private var importing = false
    @State private var action: VolumeWorkspaceOperation?
    @State private var actionFile: ProjectFile?
    @State private var input = ""
    @State private var pendingDelete: ProjectFile?
    private var canUpload: Bool { manager.permissions.has(Permission.Volumes.upload, in: environmentID) }
    private var canDelete: Bool { manager.permissions.has(Permission.Volumes.delete, in: environmentID) }
    private var identity: String { "\(manager.clientGeneration)|\(manager.client?.configuration.baseURL.absoluteString ?? "")|\(manager.currentUser?.id ?? "")|\(environmentID.rawValue)|\(volumeName)" }
    private var entries: [ProjectFile] {
        (workspace?.files ?? []).filter { file in
            let parent = file.relativePath.split(separator: "/").dropLast().joined(separator: "/")
            return parent == directory
        }.sorted { $0.isDirectory != $1.isDirectory ? $0.isDirectory : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        List {
            if unsupported {
                Text("This server does not support volume workspaces. Use the file browser to inspect this volume.")
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            if workspace?.fileTreeTruncated == true { Text("The server returned a partial file tree.").foregroundStyle(.orange) }
            if !directory.isEmpty {
                Button("Parent folder", systemImage: "arrow.up") { directory = directory.split(separator: "/").dropLast().joined(separator: "/") }
            }
            ForEach(entries, id: \.relativePath) { file in
                Button {
                    if file.isDirectory { directory = file.relativePath }
                    else { selectedFile = file }
                } label: {
                    Label(file.name, systemImage: file.isDirectory ? "folder" : "doc.text")
                }
                .contextMenu {
                    if canUpload && canDelete && file.isSymlink != true {
                        Button("Rename") { actionFile = file; input = file.name; action = .rename }
                        Button("Move") { actionFile = file; input = ""; action = .move }
                    }
                    if canDelete { Button("Delete", role: .destructive) { pendingDelete = file } }
                }
            }
            if loading { ProgressView() }
            else if entries.isEmpty && workspace != nil { Text("Empty folder").foregroundStyle(.secondary) }
        }
        .navigationTitle(directory.isEmpty ? volumeName : directory)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canUpload && workspace != nil {
                Menu("Add", systemImage: "plus") {
                    Button("New file") { actionFile = nil; input = ""; action = .createFile }
                    Button("New folder") { actionFile = nil; input = ""; action = .createFolder }
                    Button("Upload files") { importing = true }
                }
                .disabled(loading)
            }
        }
        .task(id: identity) { workspace = nil; directory = ""; selectedFile = nil; await load() }
        .refreshable { await load() }
        .sheet(isPresented: Binding(get: { selectedFile != nil }, set: { if !$0 { selectedFile = nil } })) {
            if let file = selectedFile, let workspace {
                NavigationStack {
                    VolumeWorkspaceFileView(environmentID: environmentID, volumeName: volumeName, file: file, revision: workspace.fileTreeRevision) { await load() }
                }
                .id(identity)
            }
        }
        .sheet(isPresented: Binding(get: { action != nil }, set: { if !$0 { action = nil } })) {
            NavigationStack {
                Form {
                    TextField(action == .move ? "Destination folder, empty for root" : "Name", text: $input)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    if action == .move { Text("Enter a path relative to the volume root.").font(.caption) }
                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.red)
                        Button("Refresh server files") { Task { await load() } }
                    }
                }
                .navigationTitle(action?.rawValue.replacingOccurrences(of: "_", with: " ").capitalized ?? "File")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { action = nil } }
                    ToolbarItem(placement: .confirmationAction) { Button("Apply") { Task { await applyAction() } }.disabled(loading || !validInput) }
                }
            }
        }
        .confirmationDialog("Delete \(pendingDelete?.relativePath ?? "")?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let file = pendingDelete { Task { await apply([.init(operation: .delete, relativePath: file.relativePath, recursive: file.isDirectory)]); pendingDelete = nil } }
            }
        } message: { Text("Deleting a folder also deletes its contents.") }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            Task {
                do {
                    let urls = try result.get()
                    let accessed = urls.filter { $0.startAccessingSecurityScopedResource() }
                    defer { accessed.forEach { $0.stopAccessingSecurityScopedResource() } }
                    let changes = urls.enumerated().map { index, url in
                        VolumeWorkspaceFileChange(operation: .createFile, relativePath: joined(url.lastPathComponent), uploadIndex: index)
                    }
                    await apply(changes, files: urls)
                } catch { showToast(.error(friendlyErrorMessage(error))) }
            }
        }
    }

    private var validInput: Bool {
        if action == .move { return input.isEmpty || VolumeWorkspaceDraft.validRelativePath(input) }
        return VolumeWorkspaceDraft.validRelativePath(input) && !input.contains("/")
    }
    private func joined(_ name: String) -> String { directory.isEmpty ? name : directory + "/" + name }
    private func load() async {
        guard let client = manager.client, manager.permissions.has(Permission.Volumes.read, in: environmentID) else { return }
        let key = identity
        loading = true
        defer { if key == identity { loading = false } }
        do {
            let result = try await client.volumes.workspace(envID: environmentID, name: volumeName)
            guard !Task.isCancelled, identity == key else { return }
            workspace = result; errorMessage = nil; unsupported = false
        } catch {
            guard !Task.isCancelled, identity == key else { return }
            unsupported = (error as? ArcaneError) == .notFound
            errorMessage = friendlyErrorMessage(error)
        }
    }
    private func applyAction() async {
        guard let action, validInput else { return }
        let path = actionFile?.relativePath ?? joined(input)
        if action == .createFile {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            do {
                try Data().write(to: url)
                defer { try? FileManager.default.removeItem(at: url) }
                if await apply([.init(operation: action, relativePath: path, uploadIndex: 0)], files: [url]) { self.action = nil }
            } catch { showToast(.error(friendlyErrorMessage(error))) }
        } else {
            if await apply([.init(operation: action, relativePath: path, newName: action == .rename ? input : nil, newParentPath: action == .move ? input : nil)]) { self.action = nil }
        }
    }
    @discardableResult
    private func apply(_ changes: [VolumeWorkspaceFileChange], files: [URL] = []) async -> Bool {
        guard !loading, let client = manager.client, let workspace else { return false }
        let key = identity
        loading = true
        defer { if key == identity { loading = false } }
        do {
            let result = try await client.volumes.updateWorkspace(envID: environmentID, name: volumeName,
                manifest: .init(fileTreeRevision: workspace.fileTreeRevision, fileChanges: changes), files: files)
            guard !Task.isCancelled, key == identity else { return false }
            self.workspace = result
            errorMessage = nil
            showToast(.success("Files updated"))
            return true
        } catch {
            guard !Task.isCancelled, key == identity else { return false }
            if case .conflict = error as? ArcaneError {
                errorMessage = "Files changed on the server. Refresh and review them before retrying."
            } else { errorMessage = friendlyErrorMessage(error) }
            return false
        }
    }
}
