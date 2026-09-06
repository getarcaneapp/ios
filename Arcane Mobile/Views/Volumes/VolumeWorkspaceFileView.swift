import SwiftUI
import Arcane

struct VolumeWorkspaceFileView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let environmentID: EnvironmentID
    let volumeName: String
    let file: ProjectFile
    @State var revision: String
    let onSaved: () async -> Void
    @State private var content: VolumeWorkspaceFileContent?
    @State private var draft = VolumeWorkspaceDraft()
    @State private var latestContent: VolumeWorkspaceFileContent?
    @State private var latestRevision: String?
    @State private var reviewing = false
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var downloadURL: URL?
    private var canEdit: Bool { content?.editable == true && content?.readOnlyReason == nil && manager.permissions.has(Permission.Volumes.upload, in: environmentID) }
    private var identity: String { "\(manager.clientGeneration)|\(manager.client?.configuration.baseURL.absoluteString ?? "")|\(manager.currentUser?.id ?? "")|\(environmentID.rawValue)|\(volumeName)|\(file.relativePath)" }

    var body: some View {
        VStack(alignment: .leading) {
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).padding(.horizontal) }
            if let reason = content?.readOnlyReason { Text("Read only: \(reason.replacingOccurrences(of: "_", with: " "))").font(.caption).padding(.horizontal) }
            if loading { ProgressView().frame(maxWidth: .infinity) }
            if content?.content != nil {
                CodeEditorView(text: $draft.text, language: .plaintext, readOnly: !canEdit || loading)
            } else if !loading {
                ContentUnavailableView("Preview Unavailable", systemImage: "doc", description: Text("Download this file to open it in another app."))
            }
            if draft.conflict {
                Button("Review server version") { Task { await reviewConflict() } }.padding()
            }
        }
        .navigationTitle(file.name)
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(draft.hasChanges)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(draft.hasChanges ? "Discard" : "Done") { dismiss() } }
            ToolbarItemGroup(placement: .primaryAction) {
                if let downloadURL { ShareLink(item: downloadURL) }
                else { Button("Download", systemImage: "square.and.arrow.down") { Task { await download() } }.disabled(loading) }
                if canEdit { Button("Save") { Task { await save() } }.disabled(loading || !draft.hasChanges || draft.conflict) }
            }
        }
        .task(id: identity) { await load() }
        .sheet(isPresented: $reviewing) {
            NavigationStack {
                ScrollView { Text(latestContent?.content ?? "No text content").font(.body.monospaced()).textSelection(.enabled).padding() }
                    .navigationTitle("Server version")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { reviewing = false } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Keep my draft") {
                                if let latestContent, let latestRevision {
                                    content = latestContent
                                    draft.review(latest: latestContent.content ?? "")
                                    revision = latestRevision
                                    errorMessage = nil
                                }
                                reviewing = false
                            }
                            .disabled(latestContent?.editable != true)
                        }
                    }
            }
        }
        .onDisappear { if let downloadURL { try? FileManager.default.removeItem(at: downloadURL.deletingLastPathComponent()) } }
    }

    private func load() async {
        guard let client = manager.client else { return }
        let key = identity
        loading = true
        defer { if key == identity { loading = false } }
        do {
            let result = try await client.volumes.workspaceFile(envID: environmentID, name: volumeName, relativePath: file.relativePath)
            guard !Task.isCancelled, key == identity else { return }
            content = result
            draft.load(result.content ?? "")
        } catch { if !Task.isCancelled, key == identity { errorMessage = friendlyErrorMessage(error) } }
    }

    private func save() async {
        guard canEdit, !loading, !draft.conflict, let client = manager.client else { return }
        let key = identity
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        loading = true
        defer { try? FileManager.default.removeItem(at: directory); if key == identity { loading = false } }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let updated = directory.appendingPathComponent("updated")
            let baseline = directory.appendingPathComponent("baseline")
            try Data(draft.text.utf8).write(to: updated)
            try Data(draft.baseline.utf8).write(to: baseline)
            let result = try await client.volumes.updateWorkspace(envID: environmentID, name: volumeName,
                manifest: .init(fileTreeRevision: revision, fileChanges: [.init(operation: .updateFile, relativePath: file.relativePath, uploadIndex: 0, baselineIndex: 1)]), files: [updated, baseline])
            guard !Task.isCancelled, key == identity else { return }
            revision = result.fileTreeRevision
            draft.load(draft.text)
            errorMessage = nil
            await onSaved()
            showToast(.success("File saved"))
        } catch {
            guard !Task.isCancelled, key == identity else { return }
            if case .conflict = error as? ArcaneError {
                draft.conflict = true
                errorMessage = "The server file changed. Review it before saving your draft."
            } else { errorMessage = friendlyErrorMessage(error) }
        }
    }

    private func reviewConflict() async {
        guard let client = manager.client else { return }
        let key = identity
        do {
            let tree = try await client.volumes.workspace(envID: environmentID, name: volumeName)
            let latest = try await client.volumes.workspaceFile(envID: environmentID, name: volumeName, relativePath: file.relativePath)
            guard !Task.isCancelled, key == identity else { return }
            latestContent = latest; latestRevision = tree.fileTreeRevision; reviewing = true
        } catch { if !Task.isCancelled, key == identity { errorMessage = friendlyErrorMessage(error) } }
    }

    private func download() async {
        guard let client = manager.client else { return }
        let key = identity
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = directory.appendingPathComponent(URL(fileURLWithPath: file.name).lastPathComponent)
            try await client.volumes.downloadWorkspaceFile(envID: environmentID, name: volumeName, relativePath: file.relativePath, to: target)
            guard !Task.isCancelled, key == identity else { try? FileManager.default.removeItem(at: directory); return }
            downloadURL = target
        } catch { try? FileManager.default.removeItem(at: directory); if key == identity { errorMessage = friendlyErrorMessage(error) } }
    }
}
