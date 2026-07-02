import SwiftUI
import Arcane

struct NewAPIKeyView: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let key: String

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "key.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.yellow)
                    .padding(24)
                    .glassEffectCompat(in: .circle)

                Text("Save Your API Key")
                    .font(.title2.bold())

                Text("This key will only be shown once. Make sure to save it somewhere safe.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 32)

                Text(key)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(16)
                    .glassEffectCompat(in: .rect(cornerRadius: 12))
                    .padding(.horizontal, 24)

                Button {
                    UIPasteboard.general.string = key
                    showToast(.copied("API key copied"))
                } label: {
                    Label("Copy to Clipboard", systemImage: "doc.on.clipboard")
                        .frame(maxWidth: .infinity)
                        .padding()
                }
                .glassProminentButtonStyleCompat()
                .padding(.horizontal, 24)

                Spacer()
            }
            .padding(.top, 32)
            .navigationTitle("API Key Created")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct CreateAPIKeyView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let onCreated: (String) -> Void

    @State private var name = ""
    @State private var description = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    FormTextField(
                        title: "Name",
                        placeholder: "CI deploy key",
                        text: $name
                    )
                    FormTextField(
                        title: "Description",
                        placeholder: "Optional",
                        text: $description,
                        axis: .vertical,
                        lineLimit: 2...4
                    )
                } header: {
                    Text("Key Details")
                } footer: {
                    Text("Use a name that identifies where this key will be used.")
                }
                if let error = errorMessage {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
            }
            .navigationTitle("Create API Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await createKey() } }
                        .disabled(name.isEmpty || isLoading)
                }
            }
        }
    }

    private func createKey() async {
        guard let client = manager.client else { return }
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            let body = CreateAPIKeyRequest(name: name, description: description.isEmpty ? nil : description)
            let created: APIKeyCreated = try await client.rest.post("api-keys", body: body)
            onCreated(created.key)
            dismiss()
        } catch { errorMessage = friendlyErrorMessage(error) }
    }
}

// MARK: - Container Registries View

