import SwiftUI
import Arcane

struct FederatedCredentialFormView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let credential: FederatedCredential?
    let onSaved: () async -> Void
    @State private var form: FederatedCredentialForm
    @State private var roles: [Role] = []
    @State private var environments: [Arcane.Environment] = []
    @State private var saving = false
    @State private var presentationGeneration = -1
    @State private var errorMessage: String?

    init(credential: FederatedCredential?, onSaved: @escaping () async -> Void) {
        self.credential = credential
        self.onSaved = onSaved
        _form = State(initialValue: .init(credential: credential))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Credential") {
                    TextField("Name", text: $form.name)
                    TextField("Description", text: $form.description, axis: .vertical)
                    Toggle("Enabled", isOn: $form.enabled)
                }
                Section("Trust rule") {
                    TextField("Issuer URL", text: $form.issuerUrl).keyboardType(.URL)
                    TextField("Audiences, one per line", text: $form.audiences, axis: .vertical)
                    TextField("Subject claim", text: $form.subjectClaim)
                    Picker("Match type", selection: $form.matchType) {
                        Text("Exact").tag("exact")
                        Text("Glob").tag("glob")
                    }
                    TextField("Subject match", text: $form.subjectMatch, axis: .vertical)
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                Section("Access") {
                    Picker("Role", selection: $form.roleId) {
                        Text("Choose role").tag("")
                        ForEach(roles) { Text($0.name).tag($0.id) }
                    }
                    Picker("Environment", selection: $form.environmentId) {
                        Text("Global").tag("")
                        ForEach(environments) { Text($0.name ?? $0.id).tag($0.id) }
                    }
                    LabeledContent("Token lifetime in seconds") {
                        TextField("Seconds", value: $form.tokenTtlSeconds, format: .number.grouping(.never)).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                    Toggle("Expires", isOn: $form.expires)
                        .disabled(credential?.expiresAt != nil)
                    if form.expires { DatePicker("Expiration", selection: $form.expiresAt) }
                    if credential?.expiresAt != nil { Text("This server allows changing an expiration date but does not support removing it.").font(.caption).foregroundStyle(.secondary) }
                }
                if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red) } }
                if let validation = form.validationMessage { Section { Text(validation).font(.caption).foregroundStyle(.secondary) } }
            }
            .disabled(saving)
            .navigationTitle(credential == nil ? "Create Credential" : "Edit Credential")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } }.disabled(saving || form.validationMessage != nil || manager.currentUser?.isGlobalAdmin != true) }
            }
            .task {
                guard let client = manager.client else { return }
                presentationGeneration = manager.clientGeneration
                do {
                    async let loadedRoles: [Role] = PaginationLoader.collect { start, limit in
                        let page = try await client.roles.listPaginated(start: start, limit: limit)
                        return ResourcePage(items: page.data, pagination: page.pagination)
                    }
                    async let loadedEnvironments: [Arcane.Environment] = PaginationLoader.collect { start, limit in
                        let page = try await client.environments.list(query: .init(start: start, limit: limit))
                        return ResourcePage(items: page.data, pagination: page.pagination)
                    }
                    let result = try await (loadedRoles, loadedEnvironments)
                    guard !Task.isCancelled else { return }
                    roles = result.0
                    environments = result.1
                } catch { if !Task.isCancelled { errorMessage = friendlyErrorMessage(error) } }
            }
        }
        .interactiveDismissDisabled(saving)
        .onChange(of: manager.clientGeneration) { dismiss() }
    }

    private func save() async {
        guard presentationGeneration == manager.clientGeneration, manager.currentUser?.isGlobalAdmin == true, form.validationMessage == nil, let client = manager.client else { return }
        let generation = manager.clientGeneration
        saving = true
        defer { saving = false }
        do {
            if let credential { _ = try await client.federatedCredentials.update(id: credential.id, body: form.updateRequest) }
            else { _ = try await client.federatedCredentials.create(form.createRequest) }
            guard !Task.isCancelled, generation == manager.clientGeneration else { return }
            await onSaved()
            dismiss()
            showToast(.success("Credential saved"))
        } catch { errorMessage = friendlyErrorMessage(error) }
    }
}
