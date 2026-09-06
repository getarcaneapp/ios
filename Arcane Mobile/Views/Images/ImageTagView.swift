import SwiftUI
import Arcane

struct ImageTagView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutations
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let environmentID: EnvironmentID
    let imageID: String
    @State private var repository = ""
    @State private var tag = ""
    @State private var saving = false
    @State private var saveTask: Task<Void, Never>?
    var body: some View {
        NavigationStack {
            Form {
                TextField("Repository", text: $repository)
                TextField("Tag (latest when empty)", text: $tag)
                if saving { ProgressView() }
            }
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .navigationTitle("Tag Image")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveTask = Task { await save() } }
                        .disabled(saving || repository.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .interactiveDismissDisabled(saving)
            .onChange(of: manager.clientGeneration) { saveTask?.cancel(); dismiss() }
            .onChange(of: manager.activeEnvironmentID) { saveTask?.cancel(); dismiss() }
        }
    }
    private func save() async {
        guard manager.permissions.has("images:tag", in: environmentID), let client = manager.client else { return }
        let generation = manager.clientGeneration
        saving = true
        defer { saving = false }
        do {
            _ = try await client.images.tag(envID: environmentID, imageID: imageID,
                request: .init(repository: repository.trimmingCharacters(in: .whitespacesAndNewlines),
                    tag: tag.isEmpty ? nil : tag.trimmingCharacters(in: .whitespacesAndNewlines)))
            guard !Task.isCancelled, generation == manager.clientGeneration else { return }
            mutations.markChanged(kind: .images, envID: environmentID)
            showToast(.success("Image tagged")); dismiss()
        } catch { showToast(.error(error.localizedDescription)) }
    }
}
