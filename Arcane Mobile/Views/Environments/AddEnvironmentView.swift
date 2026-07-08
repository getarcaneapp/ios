import SwiftUI
import Arcane

struct AddEnvironmentView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutationStore
    @SwiftUI.Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var url = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    let onSuccess: () async -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Environment Details") {
                    FormTextField(
                        title: "Name",
                        placeholder: "Production",
                        text: $name,
                        helper: "This is the display name shown throughout Arcane."
                    )
                    FormTextField(
                        title: "Docker Endpoint",
                        placeholder: "tcp://192.168.1.10:2375",
                        text: $url,
                        keyboardType: .URL,
                        textContentType: .URL,
                        autocapitalization: .never,
                        autocorrectionDisabled: true,
                        helper: "Use the Docker API endpoint reachable from the Arcane server."
                    )
                }
                if let error = errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add Environment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await addEnvironment() } }
                        .disabled(name.isEmpty || isLoading)
                }
            }
        }
    }

    private func addEnvironment() async {
        guard let client = manager.client else { return }
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            let body: [String: String] = ["name": name, "url": url]
            let _: Arcane.Environment = try await client.rest.post("environments", body: body)
            if let cached = manager.cached {
                await cached.invalidateGlobal(paths: ["environments"])
            }
            mutationStore.markChanged(kind: .environments)
            await onSuccess()
            dismiss()
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }
}
