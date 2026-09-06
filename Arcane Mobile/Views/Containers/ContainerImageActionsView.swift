import Arcane
import SwiftUI

struct ContainerCommitView: View {
  @SwiftUI.Environment(ArcaneClientManager.self) private var manager
  @SwiftUI.Environment(ResourceMutationStore.self) private var mutations
  @SwiftUI.Environment(\.dismiss) private var dismiss
  let environmentID: EnvironmentID
  let containerID: String
  @State private var repository = ""
  @State private var tag = "latest"
  @State private var comment = ""
  @State private var author = ""
  @State private var changes = ""
  @State private var pause = true
  @State private var busy = false
  @State private var operation: Task<Void, Never>?

  var body: some View {
    NavigationStack {
      Form {
        Section("Image") {
          TextField("Repository", text: $repository)
          TextField("Tag", text: $tag)
          TextField("Author (optional)", text: $author)
          TextField("Comment (optional)", text: $comment, axis: .vertical)
        }
        Section("Commit options") {
          Toggle("Pause container during commit", isOn: $pause)
          TextField(
            "Dockerfile instructions, one per line (optional)", text: $changes, axis: .vertical)
          Text("Mounted volume contents are excluded from the image.").foregroundStyle(.secondary)
        }
        if busy { ProgressView("Creating image…") }
      }
      .textInputAutocapitalization(.never).autocorrectionDisabled()
      .navigationTitle("Commit to Image")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }.disabled(busy)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Commit") { operation = Task { await commit() } }
            .disabled(
              busy || repository.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !manager.permissions.has("images:commit", in: environmentID))
        }
      }
      .interactiveDismissDisabled(busy)
      .onDisappear { operation?.cancel() }
      .onChange(of: manager.clientGeneration) {
        operation?.cancel()
        dismiss()
      }
      .onChange(of: manager.activeEnvironmentID) { _, newID in
        if newID != environmentID {
          operation?.cancel()
          dismiss()
        }
      }
    }
  }

  private func commit() async {
    guard let client = manager.client, manager.permissions.has("images:commit", in: environmentID)
    else { return }
    let generation = manager.clientGeneration
    busy = true
    defer { busy = false }
    do {
      _ = try await client.containers.commit(
        envID: environmentID, id: containerID,
        body: .init(
          repository: repository, tag: tag, comment: comment, author: author,
          changes: changes.components(separatedBy: .newlines).filter { !$0.isEmpty },
          noPause: !pause))
      try Task.checkCancellation()
      guard generation == manager.clientGeneration else { return }
      mutations.markChanged(kind: .images, envID: environmentID)
      showToast(.success("Image created"))
      dismiss()
    } catch is CancellationError {} catch { showToast(.error(error.localizedDescription)) }
  }
}

struct ContainerComposeView: View {
  @SwiftUI.Environment(ArcaneClientManager.self) private var manager
  @SwiftUI.Environment(\.dismiss) private var dismiss
  let environmentID: EnvironmentID
  let containerIDs: [String]
  @State private var content = ""
  @State private var loading = true
  @State private var error: String?
  @State private var createProject = false

  var body: some View {
    NavigationStack {
      Group {
        if loading {
          ProgressView("Generating Compose…")
        } else if let error {
          ContentUnavailableView(
            "Compose unavailable", systemImage: "exclamationmark.triangle", description: Text(error)
          )
        } else {
          TextEditor(text: $content).font(.system(.body, design: .monospaced))
            .textInputAutocapitalization(.never).autocorrectionDisabled().padding()
        }
      }
      .navigationTitle("Generated Compose")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
        ToolbarItemGroup(placement: .primaryAction) {
          if !loading && error == nil {
            ShareLink(item: content) { Label("Share", systemImage: "square.and.arrow.up") }
            if manager.permissions.has(Permission.Projects.create, in: environmentID) {
              Button("Create Project") { createProject = true }
            }
          }
        }
      }
      .task(id: manager.clientGeneration) {
        guard let client = manager.client else {
          loading = false
          error = "Connect to a server to continue."
          return
        }
        do {
          let response = try await client.containers.generateCompose(
            envID: environmentID, body: .init(containerIds: containerIDs))
          try Task.checkCancellation()
          content = response.composeContent
          loading = false
        } catch is CancellationError {} catch {
          loading = false
          self.error = error.localizedDescription
        }
      }
      .onChange(of: manager.activeEnvironmentID) { _, newID in
        if newID != environmentID { dismiss() }
      }
      .onChange(of: manager.clientGeneration) { dismiss() }
      .sheet(isPresented: $createProject) {
        CreateProjectView(environmentID: environmentID, prefilledCompose: content) {}
      }
    }
  }
}
