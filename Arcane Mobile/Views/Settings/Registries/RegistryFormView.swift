import SwiftUI
import Arcane

struct RegistryFormView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let registry: ContainerRegistry?
    let onSuccess: () async -> Void

    @State private var url = ""
    @State private var username = ""
    @State private var token = ""
    @State private var description = ""
    @State private var enabled = true
    @State private var insecure = false
    @State private var registryType = "generic"
    @State private var awsAccessKeyId = ""
    @State private var awsSecretAccessKey = ""
    @State private var awsRegion = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var isEditing: Bool { registry != nil }
    private var isAWS: Bool { registryType == "ecr" }

    // Picker selects between generic and ecr; legacy "custom" maps to generic.
    private var typeBinding: Binding<String> {
        Binding(
            get: { registryType == "ecr" ? "ecr" : "generic" },
            set: { registryType = $0 }
        )
    }

    // For new registries, the URL field is required and Save enables once it's set.
    // For edits, Save only enables when something actually differs from the loaded
    // record (token/awsSecretAccessKey count as changed if any value was typed).
    private var hasChanges: Bool {
        guard let registry else { return !url.isEmpty }
        let typeMatch = registryType == registry.registryType
            || (typeBinding.wrappedValue == "generic"
                && (registry.registryType == "generic" || registry.registryType == "custom"))
        return url != registry.url
            || username != registry.username
            || description != (registry.description ?? "")
            || enabled != registry.enabled
            || insecure != registry.insecure
            || !typeMatch
            || awsAccessKeyId != (registry.awsAccessKeyId ?? "")
            || awsRegion != (registry.awsRegion ?? "")
            || !token.isEmpty
            || !awsSecretAccessKey.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Registry Details") {
                    FormTextField(
                        title: "Registry URL",
                        placeholder: "registry.example.com",
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
                    FormPicker(
                        title: "Type",
                        selection: typeBinding,
                        helper: "Choose AWS ECR only for registries that need AWS credentials."
                    ) {
                        Text("Generic").tag("generic")
                        Text("AWS ECR").tag("ecr")
                    }
                    Toggle("Enabled", isOn: $enabled)
                    Toggle("Insecure", isOn: $insecure)
                }

                if !isAWS {
                    Section("Credentials (optional)") {
                        FormTextField(
                            title: "Username",
                            placeholder: "Optional",
                            text: $username,
                            autocapitalization: .never,
                            autocorrectionDisabled: true
                        )
                        FormSecureField(
                            title: isEditing ? "New Token or Password" : "Token or Password",
                            placeholder: isEditing ? "Leave blank to keep current value" : "Optional",
                            text: $token
                        )
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if isAWS {
                    Section("AWS ECR") {
                        FormTextField(
                            title: "Access Key ID",
                            placeholder: "AKIA...",
                            text: $awsAccessKeyId,
                            autocapitalization: .never,
                            autocorrectionDisabled: true
                        )
                        FormSecureField(
                            title: isEditing ? "New Secret Access Key" : "Secret Access Key",
                            placeholder: isEditing ? "Leave blank to keep current value" : "Required",
                            text: $awsSecretAccessKey
                        )
                        FormTextField(
                            title: "Region",
                            placeholder: "us-east-1",
                            text: $awsRegion,
                            autocapitalization: .never,
                            autocorrectionDisabled: true
                        )
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if let error = errorMessage {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
            }
            .animation(Motion.entrance, value: isAWS)
            .navigationTitle(isEditing ? "Edit Registry" : "Add Registry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Add") { Task { await saveRegistry() } }
                        .disabled(url.isEmpty || isLoading || !hasChanges)
                }
            }
            .onAppear { populateFields() }
        }
    }

    private func populateFields() {
        guard let registry else { return }
        url = registry.url
        username = registry.username
        description = registry.description ?? ""
        enabled = registry.enabled
        insecure = registry.insecure
        registryType = registry.registryType
        awsAccessKeyId = registry.awsAccessKeyId ?? ""
        awsRegion = registry.awsRegion ?? ""
    }

    private func saveRegistry() async {
        guard let client = manager.client else { return }
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            if let registry {
                let body = UpdateContainerRegistryRequest(
                    url: url,
                    username: username.nilIfEmpty,
                    token: token.nilIfEmpty,
                    description: description.nilIfEmpty,
                    insecure: insecure,
                    enabled: enabled,
                    registryType: registryType.nilIfEmpty,
                    awsAccessKeyId: awsAccessKeyId.nilIfEmpty,
                    awsSecretAccessKey: awsSecretAccessKey.nilIfEmpty,
                    awsRegion: awsRegion.nilIfEmpty
                )
                let _: ContainerRegistry = try await client.rest.put("container-registries/\(registry.id)", body: body)
            } else {
                let body = CreateContainerRegistryRequest(
                    url: url,
                    username: username,
                    token: token,
                    description: description.nilIfEmpty,
                    insecure: insecure,
                    enabled: enabled,
                    registryType: registryType.isEmpty ? "custom" : registryType,
                    awsAccessKeyId: awsAccessKeyId,
                    awsSecretAccessKey: awsSecretAccessKey,
                    awsRegion: awsRegion
                )
                let _: ContainerRegistry = try await client.rest.post("container-registries", body: body)
            }
            await onSuccess(); dismiss()
        } catch { errorMessage = friendlyErrorMessage(error) }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
