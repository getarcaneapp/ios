import SwiftUI
import Arcane

struct TemplateRegistryFormView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let registry: TemplateRegistry?
    let onSuccess: () async -> Void

    @State private var name = ""
    @State private var url = ""
    @State private var description = ""
    @State private var enabled = true
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var isEditing: Bool { registry != nil }

    private var hasChanges: Bool {
        guard let registry else { return !name.isEmpty || !url.isEmpty }
        return name != registry.name
            || url != registry.url
            || description != registry.description
            || enabled != registry.enabled
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Template Registry") {
                    FormTextField(
                        title: "Name",
                        placeholder: "Company templates",
                        text: $name
                    )
                    FormTextField(
                        title: "URL",
                        placeholder: "https://example.com/templates.json",
                        text: $url,
                        keyboardType: .URL,
                        textContentType: .URL,
                        autocapitalization: .never,
                        autocorrectionDisabled: true
                    )
                    FormTextField(
                        title: "Description",
                        placeholder: "Optional",
                        text: $description,
                        axis: .vertical,
                        lineLimit: 2...4
                    )
                    Toggle("Enabled", isOn: $enabled)
                }

                if let error = errorMessage {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
            }
            .navigationTitle(isEditing ? "Edit Template Registry" : "Add Template Registry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Add") { Task { await saveRegistry() } }
                        .disabled(name.isEmpty || url.isEmpty || isLoading || !hasChanges)
                }
            }
            .onAppear { populateFields() }
        }
    }

    private func populateFields() {
        guard let registry else { return }
        name = registry.name
        url = registry.url
        description = registry.description
        enabled = registry.enabled
    }

    private func saveRegistry() async {
        guard let client = manager.client else { return }
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            if let registry {
                let body = UpdateTemplateRegistryRequest(
                    name: name,
                    url: url,
                    description: description,
                    enabled: enabled
                )
                let _: TemplateRegistry = try await client.rest.put("templates/registries/\(registry.id)", body: body)
            } else {
                let body = CreateTemplateRegistryRequest(
                    name: name,
                    url: url,
                    description: description,
                    enabled: enabled
                )
                let _: TemplateRegistry = try await client.rest.post("templates/registries", body: body)
            }
            await onSuccess(); dismiss()
        } catch { errorMessage = friendlyErrorMessage(error) }
    }
}

