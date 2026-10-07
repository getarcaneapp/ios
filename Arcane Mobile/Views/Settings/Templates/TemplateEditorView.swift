import SwiftUI
import Arcane

struct TemplateEditorView: View {
    let mode: TemplateEditorMode
    let onSuccess: () async -> Void

    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @State private var previewSession = ComposePreviewSession()
    private var previewEnabled: Bool { previewSession.isEnabled }
    @State private var name = ""
    @State private var description = ""
    @State private var compose = ""
    @State private var environment = ""
    @State private var originalName = ""
    @State private var originalDescription = ""
    @State private var originalCompose = ""
    @State private var originalEnvironment = ""
    @State private var sessionIdentity: String?
    @State private var isLoaded = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var confirmDiscard = false

    private var isDefaults: Bool {
        if case .defaults = mode { return true }
        return false
    }

    private var title: String {
        switch mode {
        case .create: "Create Template"
        case .edit: "Edit Template"
        case .defaults: "Default Templates"
        }
    }

    private var hasChanges: Bool {
        name != originalName || description != originalDescription
            || compose != originalCompose || environment != originalEnvironment
    }

    private var canSave: Bool {
        guard isLoaded, sessionIdentity == manager.cacheSessionIdentity else { return false }
        let permission: String
        if case .create = mode { permission = Permission.Templates.create }
        else { permission = Permission.Templates.update }
        return manager.permissions.has(permission, in: nil)
            && (isDefaults || !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                if isLoaded {
                    if !isDefaults {
                        Section("Template") {
                            FormTextField(title: "Name", placeholder: "My template", text: $name)
                            FormTextField(title: "Description", placeholder: "Optional", text: $description,
                                          axis: .vertical, lineLimit: 2...4)
                        }
                    }
                    Section {
                        NavigationLink("Compose file") {
                            fileEditor(isEnvironment: false)
                        }
                        NavigationLink("Environment variables") {
                            fileEditor(isEnvironment: true)
                        }
                    } header: {
                        Text(previewEnabled ? "Files · Preview" : "Files")
                    } footer: {
                        if isDefaults {
                            Text("Defaults provide the starting Compose and environment files for new projects.")
                        }
                    }
                } else if errorMessage == nil {
                    ProgressView("Loading template…")
                }
                if isLoaded, sessionIdentity != manager.cacheSessionIdentity {
                    Section {
                        Label("The connection changed. Close this editor and reopen it on the intended server before saving.",
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                        if !isLoaded { Button("Try Again") { Task { await load() } } }
                    }
                }
            }
            .disabled(isSaving)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if hasChanges { confirmDiscard = true } else { dismiss() }
                    }
                    .disabled(isSaving)
                }
                AppToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(!canSave || !hasChanges || isSaving)
                }
            }
            .confirmationDialog("Discard template changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) {}
            }
            .interactiveDismissDisabled(hasChanges || isSaving)
            .task { if !isLoaded { await load() } }
        }
    }

    @ViewBuilder
    private func fileEditor(isEnvironment: Bool) -> some View {
        Group {
            if previewEnabled {
                if isEnvironment { EnvPreviewEditor(text: $environment, readOnly: !canSave || isSaving) }
                else { ComposePreviewEditor(text: $compose, readOnly: !canSave || isSaving) }
            } else {
                CodeEditorView(text: isEnvironment ? $environment : $compose,
                               language: isEnvironment ? .env : .yaml, readOnly: !canSave || isSaving)
            }
        }
        .navigationTitle(isEnvironment ? ".env" : "compose.yml")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func load() async {
        guard let client = manager.client else { return }
        let identity = manager.cacheSessionIdentity
        errorMessage = nil
        do {
            switch mode {
            case .create: break
            case .edit(let template):
                guard !template.isRemote, manager.permissions.has(Permission.Templates.read, in: nil) else { return }
                let loaded = try await RemoteDataLimits.boundedAPIResponse(
                    client: client, path: "templates/\(ArcaneAPIHelpers.escapedPathComponent(template.id))/content",
                    as: TemplateContent.self, maximumBytes: RemoteDataLimits.maximumTemplateBytes)
                guard identity == manager.cacheSessionIdentity else { return }
                name = loaded.template.name
                description = loaded.template.description
                compose = loaded.content
                environment = loaded.envContent
            case .defaults:
                guard manager.permissions.has(Permission.Templates.read, in: nil) else { return }
                let defaults = try await client.templates.getDefaults()
                guard identity == manager.cacheSessionIdentity else { return }
                compose = defaults.composeTemplate
                environment = defaults.envTemplate
            }
            sessionIdentity = identity
            originalName = name
            originalDescription = description
            originalCompose = compose
            originalEnvironment = environment
            isLoaded = true
        } catch { errorMessage = friendlyErrorMessage(error) }
    }

    private func save() async {
        guard canSave, !isSaving, let client = manager.client else { return }
        guard compose.utf8.count + environment.utf8.count <= RemoteDataLimits.maximumTemplateBytes else {
            errorMessage = "This template exceeds the supported editor size."
            return
        }
        let identity = manager.cacheSessionIdentity
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            if previewEnabled { try ProjectDraftSnapshot(compose: compose, environment: environment).validateSyntax() }
            switch mode {
            case .create:
                _ = try await client.templates.create(CreateTemplate(name: name, description: description,
                                                                     content: compose, envContent: environment))
            case .edit(let template):
                guard !template.isRemote else { return }
                let latest = try await client.templates.getContent(id: template.id)
                guard identity == manager.cacheSessionIdentity else { return }
                guard latest.content == originalCompose, latest.envContent == originalEnvironment,
                      latest.template.name == originalName, latest.template.description == originalDescription else {
                    errorMessage = "This template changed on the server. Your draft is preserved. Reopen the template to load the latest version."
                    return
                }
                _ = try await client.templates.update(id: template.id, body: UpdateTemplate(
                    name: name, description: description, content: compose, envContent: environment))
            case .defaults:
                let latest = try await client.templates.getDefaults()
                guard identity == manager.cacheSessionIdentity else { return }
                guard latest.composeTemplate == originalCompose, latest.envTemplate == originalEnvironment else {
                    errorMessage = "Default templates changed on the server. Your draft is preserved. Reopen this editor to load the latest version."
                    return
                }
                try await client.templates.saveDefaults(SaveDefaultTemplates(composeContent: compose, envContent: environment))
            }
            guard identity == manager.cacheSessionIdentity else { return }
            showToast(.success("Template saved"))
            await onSuccess()
            dismiss()
        } catch { errorMessage = friendlyErrorMessage(error) }
    }
}
