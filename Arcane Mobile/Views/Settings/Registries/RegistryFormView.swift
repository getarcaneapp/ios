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
    @State private var repositoryNameRows: [StableStringRow] = []
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
        guard let registry else {
            return !url.isEmpty
                || !username.isEmpty
                || !token.isEmpty
                || !description.isEmpty
                || !enabled
                || insecure
                || typeBinding.wrappedValue != "generic"
                || !awsAccessKeyId.isEmpty
                || !awsSecretAccessKey.isEmpty
                || !awsRegion.isEmpty
                || !repositoryNameRows.isEmpty
        }
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
            || (manager.supportsPost26MobileFeatures
                && repositoryNames != registry.repositoryNames)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
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
                        selection: typeBinding
                    ) {
                        Text("Generic").tag("generic")
                        Text("AWS ECR").tag("ecr")
                    }
                    Toggle("Enabled", isOn: $enabled)
                    Toggle("Insecure", isOn: $insecure)
                } header: {
                    Text("Registry Details")
                } footer: {
                    Text("Choose AWS ECR only for registries that need AWS credentials.")
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

                if manager.supportsPost26MobileFeatures {
                    Section {
                        ForEach($repositoryNameRows) { $row in
                            HStack {
                                TextField("owner/image", text: $row.value)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                Button(role: .destructive) {
                                    repositoryNameRows.removeAll { $0.id == row.id }
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove repository name")
                            }
                        }
                        Button {
                            repositoryNameRows.append(StableStringRow())
                        } label: {
                            Label("Add Repository Name", systemImage: "plus")
                        }
                    } header: {
                        Text("Repository Names")
                    } footer: {
                        Text("Limit registry checks to these repositories, in the order shown.")
                    }
                }

                if let error = errorMessage {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
            }
            .animation(Motion.entrance, value: isAWS)
            .navigationTitle(isEditing ? "Edit Registry" : "Add Registry")
            .navigationBarTitleDisplayMode(.inline)
            .settingsSaveBar(
                hasChanges: hasChanges,
                isSaving: isLoading,
                canSave: !url.isEmpty,
                saveAccessibilityLabel: isEditing ? "Save" : "Add",
                onSave: { Task { await saveRegistry() } },
                onRevert: revertChanges
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .onAppear { populateFields() }
        }
    }

    private func populateFields() {
        guard let registry else {
            url = ""
            username = ""
            token = ""
            description = ""
            enabled = true
            insecure = false
            registryType = "generic"
            awsAccessKeyId = ""
            awsSecretAccessKey = ""
            awsRegion = ""
            repositoryNameRows = []
            return
        }
        url = registry.url
        username = registry.username
        token = ""
        description = registry.description ?? ""
        enabled = registry.enabled
        insecure = registry.insecure
        registryType = registry.registryType
        awsAccessKeyId = registry.awsAccessKeyId ?? ""
        awsSecretAccessKey = ""
        awsRegion = registry.awsRegion ?? ""
        repositoryNameRows = registry.repositoryNames.map { StableStringRow(value: $0) }
    }

    private func revertChanges() {
        populateFields()
        errorMessage = nil
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
                    awsRegion: awsRegion.nilIfEmpty,
                    repositoryNames: registryRepositoryNames(
                        rows: repositoryNameRows,
                        supported: manager.supportsPost26MobileFeatures
                    )
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
                    awsRegion: awsRegion,
                    repositoryNames: registryRepositoryNames(
                        rows: repositoryNameRows,
                        supported: manager.supportsPost26MobileFeatures
                    )
                )
                let _: ContainerRegistry = try await client.rest.post("container-registries", body: body)
            }
            await onSuccess(); dismiss()
        } catch { errorMessage = friendlyErrorMessage(error) }
    }

    private var repositoryNames: [String] {
        repositoryNameRows.compactMap { row in
            let value = row.value.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
    }
}

func registryRepositoryNames(rows: [StableStringRow], supported: Bool) -> [String]? {
    guard supported else { return nil }
    return rows.compactMap { row in
        let value = row.value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
