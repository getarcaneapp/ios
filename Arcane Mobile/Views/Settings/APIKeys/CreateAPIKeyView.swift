import SwiftUI
import Arcane

struct NewAPIKeyView: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let presentation: APIKeySecretPresentation

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.yellow)
                        .padding(24)
                        .glassEffectCompat(in: .circle)

                    Text(presentation.heading)
                        .font(.title2.bold())

                    Text(presentation.message)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 32)

                    Text(presentation.key)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassEffectCompat(in: .rect(cornerRadius: Radius.nested))
                        .padding(.horizontal, 24)

                    if let warning = presentation.warning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.12), in: .rect(cornerRadius: Radius.nested))
                            .padding(.horizontal, 24)
                    }

                    Button {
                        UIPasteboard.general.string = presentation.key
                        showToast(.copied("API key copied"))
                    } label: {
                        Label("Copy to Clipboard", systemImage: "doc.on.clipboard")
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                    .glassProminentButtonStyleCompat()
                    .padding(.horizontal, 24)
                }
                .padding(.top, 32)
                .padding(.bottom, 24)
            }
            .navigationTitle(presentation.navigationTitle)
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
    let onCreated: (APIKeyCreated) -> Void

    @State private var name = ""
    @State private var description = ""
    @State private var hasExpiration = false
    @State private var expiresAt = Calendar.current.date(byAdding: .day, value: 90, to: Date()) ?? Date()
    @State private var selectedPermissions: Set<String> = []
    @State private var permissionSearch = ""
    @State private var loadedManifest: PermissionsManifest?
    @State private var isLoadingPermissions = false
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var supportsRBAC: Bool {
        manager.serverCapabilities?.supportsRoleManagement == true
    }

    private var manifest: PermissionsManifest? {
        loadedManifest ?? manager.permissionsManifest
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isLoading
            && (!supportsRBAC || (manifest != nil && !selectedPermissions.isEmpty))
    }

    var body: some View {
        NavigationStack {
            Group {
                if supportsRBAC {
                    form
                        .searchable(
                            text: $permissionSearch,
                            placement: .navigationBarDrawer(displayMode: .always),
                            prompt: "Search permissions"
                        )
                } else {
                    form
                }
            }
            .navigationTitle("Create API Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isLoading)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await createKey() } }
                        .disabled(!canCreate)
                }
            }
            .task { await loadManifestIfNeeded() }
        }
    }

    private var form: some View {
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

            Section {
                Toggle("Set Expiration", isOn: $hasExpiration)
                if hasExpiration {
                    DatePicker(
                        "Expiration Date",
                        selection: $expiresAt,
                        in: Date()...,
                        displayedComponents: .date
                    )
                }
            } header: {
                Text("Expiration")
            } footer: {
                Text(hasExpiration ? "The key stops working after this date." : "The key remains active until it is deleted or rotated.")
            }

            if supportsRBAC {
                if let manifest {
                    PermissionPickerView(
                        manifest: manifest,
                        selected: $selectedPermissions,
                        search: permissionSearch
                    )
                    Section {} footer: {
                        Text("Select at least one permission. API keys cannot exceed your own access.")
                    }
                } else {
                    Section {
                        HStack {
                            Spacer()
                            if isLoadingPermissions {
                                ProgressView("Loading permissions…")
                            } else {
                                Label("Permissions unavailable", systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                }
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        .disabled(isLoading)
    }

    private func createKey() async {
        guard let client = manager.client else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let permissions: [ApiKeyPermissionGrant]? = supportsRBAC
            ? selectedPermissions.sorted().map { ApiKeyPermissionGrant(permission: $0) }
            : nil
        let body = APIKeyMutationRequest(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : description.trimmingCharacters(in: .whitespacesAndNewlines),
            expiresAt: hasExpiration ? expiresAt : nil,
            permissions: permissions
        )

        do {
            let created: APIKeyCreated = try await client.rest.post("api-keys", body: body)
            onCreated(created)
            dismiss()
        } catch let ArcaneError.validation(fields) {
            errorMessage = formatValidationFields(fields)
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func loadManifestIfNeeded() async {
        guard supportsRBAC, manifest == nil, let client = manager.client else { return }
        isLoadingPermissions = true
        defer { isLoadingPermissions = false }
        do {
            loadedManifest = try await client.roles.availablePermissions()
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }
}

struct EditAPIKeyView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.dismiss) private var dismiss

    let apiKey: APIKey
    let metadata: APIKeyServerMetadata?
    let onSaved: (APIKey) async -> Void
    private let initialExpiresAt: Date

    @State private var name: String
    @State private var description: String
    @State private var hasExpiration: Bool
    @State private var expiresAt: Date
    @State private var selectedPermissions: Set<String>
    @State private var permissionSearch = ""
    @State private var loadedManifest: PermissionsManifest?
    @State private var isLoadingPermissions = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(
        apiKey: APIKey,
        metadata: APIKeyServerMetadata?,
        onSaved: @escaping (APIKey) async -> Void
    ) {
        self.apiKey = apiKey
        self.metadata = metadata
        self.onSaved = onSaved
        let initialExpiresAt = apiKey.expiresAt
            ?? Calendar.current.date(byAdding: .day, value: 90, to: Date())
            ?? Date()
        self.initialExpiresAt = initialExpiresAt
        _name = State(initialValue: apiKey.name)
        _description = State(initialValue: apiKey.description ?? "")
        _hasExpiration = State(initialValue: apiKey.expiresAt != nil)
        _expiresAt = State(initialValue: initialExpiresAt)
        _selectedPermissions = State(
            initialValue: Set(metadata?.permissions?.map(\.permission) ?? [])
        )
    }

    private var supportsRBAC: Bool {
        manager.serverCapabilities?.supportsRoleManagement == true
    }

    private var isPersonal: Bool {
        metadata?.kind == "personal"
    }

    private var manifest: PermissionsManifest? {
        loadedManifest ?? manager.permissionsManifest
    }

    private var showsPermissionPicker: Bool {
        supportsRBAC && !isPersonal && metadata?.permissions != nil && manifest != nil
    }

    private var hasChanges: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines) != apiKey.name
            || description != (apiKey.description ?? "")
            || (hasExpiration ? expiresAt : nil) != apiKey.expiresAt
            || (showsPermissionPicker && selectedPermissions != Set(metadata?.permissions?.map(\.permission) ?? []))
    }

    private var canSave: Bool {
        !isSaving
            && hasChanges
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!showsPermissionPicker || !selectedPermissions.isEmpty)
    }

    var body: some View {
        NavigationStack {
            Group {
                if showsPermissionPicker {
                    form
                        .searchable(
                            text: $permissionSearch,
                            placement: .navigationBarDrawer(displayMode: .always),
                            prompt: "Search permissions"
                        )
                } else {
                    form
                }
            }
            .navigationTitle("Edit API Key")
            .navigationBarTitleDisplayMode(.inline)
            .settingsSaveBar(
                hasChanges: hasChanges,
                isSaving: isSaving,
                canSave: canSave,
                onSave: { Task { await save() } },
                onRevert: revertChanges
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
            }
            .task { await loadManifestIfNeeded() }
        }
    }

    private var form: some View {
        Form {
            Section {
                FormTextField(title: "Name", placeholder: "CI deploy key", text: $name)
                FormTextField(
                    title: "Description",
                    placeholder: "Optional",
                    text: $description,
                    axis: .vertical,
                    lineLimit: 2...4
                )
            } header: {
                Text("Key Details")
            }

            Section {
                if apiKey.expiresAt == nil {
                    Toggle("Set Expiration", isOn: $hasExpiration)
                }
                if hasExpiration {
                    DatePicker("Expiration Date", selection: $expiresAt, displayedComponents: .date)
                } else {
                    LabeledContent("Expiration", value: "Never")
                }
            } header: {
                Text("Expiration")
            } footer: {
                if apiKey.expiresAt != nil {
                    Text("The expiration date can be changed but cannot be removed from an existing key.")
                }
            }

            if supportsRBAC {
                if isPersonal {
                    Section {
                        Label("Personal keys inherit the assigned user's role permissions.", systemImage: "person.badge.key.fill")
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("Permissions")
                    }
                } else if let manifest, metadata?.permissions != nil {
                    PermissionPickerView(
                        manifest: manifest,
                        selected: $selectedPermissions,
                        search: permissionSearch
                    )
                    Section {} footer: {
                        Text("Select at least one permission. API keys cannot exceed your own access.")
                    }
                } else {
                    Section {
                        if isLoadingPermissions {
                            ProgressView("Loading permissions…")
                        } else {
                            PartialDataNotice(message: "Existing permissions will be preserved because they could not be loaded.")
                        }
                    } header: {
                        Text("Permissions")
                    }
                }
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        .disabled(isSaving)
    }

    private func revertChanges() {
        name = apiKey.name
        description = apiKey.description ?? ""
        hasExpiration = apiKey.expiresAt != nil
        expiresAt = initialExpiresAt
        selectedPermissions = Set(metadata?.permissions?.map(\.permission) ?? [])
        errorMessage = nil
    }

    private func save() async {
        guard let client = manager.client else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        let permissions: [ApiKeyPermissionGrant]? = showsPermissionPicker
            ? selectedPermissions.sorted().map { ApiKeyPermissionGrant(permission: $0) }
            : nil
        let body = APIKeyMutationRequest(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            expiresAt: hasExpiration ? expiresAt : nil,
            permissions: permissions
        )

        do {
            let path = "api-keys/\(ArcaneAPIHelpers.escapedPathComponent(apiKey.id))"
            let updated: APIKey = try await client.rest.put(path, body: body)
            await onSaved(updated)
            showToast(.success("API key updated"))
            dismiss()
        } catch let ArcaneError.validation(fields) {
            errorMessage = formatValidationFields(fields)
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func loadManifestIfNeeded() async {
        guard supportsRBAC, !isPersonal, manifest == nil, let client = manager.client else { return }
        isLoadingPermissions = true
        defer { isLoadingPermissions = false }
        loadedManifest = try? await client.roles.availablePermissions()
    }
}
