import SwiftUI
import Arcane

struct ProjectDetailView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutationStore
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let project: ProjectDetails
    let environmentID: EnvironmentID

    @State private var refreshedProject: ProjectDetails?
    @State private var isLoading = false
    @State private var isActioning = false
    @State private var actionStatus: String?
    @State private var showLogs = false
    @State private var showCompose = false
    @State private var showDeleteConfirm = false
    @State private var streamingAction: StreamingAction?
    @State private var errorMessage: String?
    @State private var runningActionID: String?

    private var currentProject: ProjectDetails { refreshedProject ?? project }
    private var isRunning: Bool { currentProject.status.lowercased() == "running" }
    private var hasBuild: Bool { currentProject.hasBuildDirective == true }

    struct StreamingAction: Identifiable {
        let id = UUID()
        let title: String
        let path: String
        let method: String
        let body: Data?
    }

    var body: some View {
        List {
            Section {
                projectHeader
            }

            if let status = actionStatus {
                Section {
                    HStack(spacing: 10) {
                        if isActioning {
                            ProgressView().scaleEffect(0.8)
                        }
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }

            Section("Info") {
                LabeledContent("Status", value: currentProject.status.capitalized)
                LabeledContent("Services", value: "\(currentProject.serviceCount)")
                LabeledContent("Running", value: "\(currentProject.runningCount)")
                LabeledContent("Created", value: currentProject.createdAt)
                if let version = currentProject.composeVersion {
                    LabeledContent("Compose Version", value: version)
                }
            }
        }
        .listStyle(.insetGrouped)
        .softTopScrollEdgeEffectCompat()
        .actionToolbar(
            items: actionItems,
            runningItemID: runningActionID,
            isDisabled: isActioning,
            resourceName: currentProject.displayName
        )
        .navigationTitle(currentProject.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        showCompose = true
                    } label: {
                        Label("View Compose File", systemImage: "doc.text")
                    }
                    if currentProject.isArchived {
                        Button {
                            Task { await unarchiveProject() }
                        } label: {
                            Label("Unarchive Project", systemImage: "tray.and.arrow.up")
                        }
                    } else {
                        Button {
                            Task { await archiveProject() }
                        } label: {
                            Label("Archive Project", systemImage: "archivebox")
                        }
                    }
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        DestructiveLabel(text: "Delete Project")
                    }
                    .tint(.red)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(isActioning)
            }
        }
        .task { await loadProject() }
        .refreshable { await loadProject(refresh: true) }
        .sheet(isPresented: $showLogs) {
            LogsView(
                title: currentProject.displayName,
                logStream: manager.client?.projects.logs(envID: environmentID, projectID: project.id)
            )
        }
        .sheet(isPresented: $showCompose) {
            ComposeFileView(
                projectID: project.id,
                projectName: currentProject.name,
                environmentID: environmentID
            )
        }
        .sheet(item: $streamingAction) { action in
            StreamingActionView(
                title: action.title,
                path: action.path,
                method: action.method,
                body: action.body
            ) {
                await invalidateProjectCaches()
                mutationStore.markChanged(kind: .projects, envID: environmentID)
                await loadProject(refresh: true)
                HapticsManager.success()
                ReviewPrompter.shared.recordSuccess()
            }
        }
        .alert("Delete Project", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) { Task { await deleteProject(removeFiles: false) } }
            Button("Delete and Remove Files", role: .destructive) {
                Task { await deleteProject(removeFiles: true) }
            }
            Button("Cancel", role: .cancel) { showDeleteConfirm = false }
        } message: {
            Text("Remove the project from Arcane, or also remove its files from disk.")
        }
    }

    private var projectHeader: some View {
        HStack(spacing: 16) {
            CachedAsyncImage(url: currentProject.iconUrl, size: 56) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.title)
                    .foregroundStyle(.indigo)
                    .frame(width: 56, height: 56)
                    .glassEffectCompat(in: .circle)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(currentProject.displayName).font(.title3.bold())
                let count = currentProject.serviceCount
                Text("\(count) service\(count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
                StatusBadge(status: currentProject.status).padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
    }

    private var actionItems: [ActionButtonItem] {
        var items: [ActionButtonItem] = []

        if isRunning {
            items.append(ActionButtonItem(
                id: "stop",
                title: "Stop",
                systemImage: "stop.fill",
                tint: .red,
                role: .destructive
            ) {
                Task { await performSimpleAction(suffix: "down", label: "Stopping", actionID: "stop") }
            })
            items.append(ActionButtonItem(
                id: "restart",
                title: "Restart",
                systemImage: "arrow.clockwise",
                tint: .orange
            ) {
                Task { await performSimpleAction(suffix: "restart", label: "Restarting", actionID: "restart") }
            })
        } else {
            items.append(ActionButtonItem(
                id: "start",
                title: "Deploy",
                systemImage: "play.fill",
                tint: .green
            ) {
                startStreamingAction(suffix: "up", title: "Deploy \(currentProject.displayName)")
            })
        }

        items.append(ActionButtonItem(
            id: "redeploy",
            title: "Redeploy",
            systemImage: "arrow.triangle.2.circlepath",
            tint: .purple
        ) {
            startStreamingAction(suffix: "redeploy", title: "Redeploy \(currentProject.displayName)")
        })

        items.append(ActionButtonItem(
            id: "pull",
            title: "Pull",
            systemImage: "arrow.down",
            tint: .accentColor
        ) {
            startStreamingAction(suffix: "pull", title: "Pull Images")
        })

        if hasBuild {
            items.append(ActionButtonItem(
                id: "build",
                title: "Build",
                systemImage: "hammer.fill",
                tint: .indigo
            ) {
                startStreamingAction(suffix: "build", title: "Build Images")
            })
        }

        items.append(ActionButtonItem(
            id: "logs",
            title: "Logs",
            systemImage: "doc.text.fill",
            tint: .secondary
        ) {
            showLogs = true
        })

        return items
    }

    // MARK: - Actions

    private func startStreamingAction(suffix: String, title: String) {
        guard let client = manager.client else { return }
        let path = client.rest.environmentPath(environmentID, "projects/\(project.id)/\(suffix)")
        errorMessage = nil
        actionStatus = nil
        streamingAction = StreamingAction(
            title: title,
            path: path,
            method: "POST",
            body: nil
        )
    }

    private func performSimpleAction(suffix: String, label: String, actionID: String? = nil) async {
        guard let client = manager.client else { return }
        isActioning = true
        runningActionID = actionID
        actionStatus = "\(label)…"
        errorMessage = nil
        defer {
            isActioning = false
            runningActionID = nil
        }
        do {
            let path = client.rest.environmentPath(environmentID, "projects/\(project.id)/\(suffix)")
            let _: DataResponse<String> = try await client.rest.post(path, body: String?.none)
            actionStatus = "Done."
            await invalidateProjectCaches()
            mutationStore.markChanged(kind: .projects, envID: environmentID)
            await loadProject(refresh: true)
            HapticsManager.success()
            ReviewPrompter.shared.recordSuccess()
        } catch {
            errorMessage = friendlyErrorMessage(error)
            actionStatus = nil
            HapticsManager.warning()
        }
    }

    private func deleteProject(removeFiles: Bool) async {
        guard let client = manager.client else { return }
        isActioning = true
        actionStatus = "Deleting…"
        errorMessage = nil
        defer { isActioning = false }
        do {
            let path = client.rest.environmentPath(environmentID, "projects/\(project.id)/destroy")
            let request = DestroyProjectRequest(removeFiles: removeFiles, removeVolumes: false)
            let _: DataResponse<String> = try await client.transport.request(path, method: "DELETE", body: request)
            await invalidateProjectCaches()
            mutationStore.markChanged(kind: .projects, envID: environmentID)
            dismiss()
        } catch {
            errorMessage = friendlyErrorMessage(error)
            actionStatus = nil
        }
    }

    private func archiveProject() async {
        guard let client = manager.client else { return }
        isActioning = true
        actionStatus = "Archiving…"
        errorMessage = nil
        defer { isActioning = false }
        do {
            let path = client.rest.environmentPath(environmentID, "projects/\(project.id)/archive")
            let _: DataResponse<String> = try await client.rest.post(path, body: String?.none)
            await invalidateProjectCaches()
            mutationStore.markChanged(kind: .projects, envID: environmentID)
            dismiss()
        } catch {
            errorMessage = friendlyErrorMessage(error)
            actionStatus = nil
        }
    }

    private func unarchiveProject() async {
        guard let client = manager.client else { return }
        isActioning = true
        actionStatus = "Unarchiving…"
        errorMessage = nil
        defer { isActioning = false }
        do {
            let path = client.rest.environmentPath(environmentID, "projects/\(project.id)/unarchive")
            let _: DataResponse<String> = try await client.rest.post(path, body: String?.none)
            await invalidateProjectCaches()
            mutationStore.markChanged(kind: .projects, envID: environmentID)
            dismiss()
        } catch {
            errorMessage = friendlyErrorMessage(error)
            actionStatus = nil
        }
    }

    private func loadProject(refresh: Bool = false) async {
        guard let client = manager.client, let cached = manager.cached else { return }
        if refreshedProject == nil { isLoading = true }
        defer { isLoading = false }
        do {
            let path = client.rest.environmentPath(environmentID, "projects/\(project.id)")
            if let result: ProjectDetails = try await cached.get(
                path, as: ProjectDetails.self, policy: .projects,
                envID: environmentID, refresh: refresh,
                onFresh: { fresh in refreshedProject = fresh }
            ) {
                refreshedProject = result
            }
            errorMessage = nil
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func invalidateProjectCaches() async {
        guard let cached = manager.cached, let client = manager.client else { return }
        await cached.invalidate(envID: environmentID, paths: [
            client.rest.environmentPath(environmentID, "projects") + "*",
            client.rest.environmentPath(environmentID, "projects/*"),
            client.rest.environmentPath(environmentID, "containers"),
            client.rest.environmentPath(environmentID, "containers/*")
        ])
    }
}

struct ComposeFileView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let projectID: String
    let projectName: String
    let environmentID: EnvironmentID

    @State private var name: String = ""
    @State private var composeContent: String = ""
    @State private var envContent: String = ""
    @State private var originalCompose: String = ""
    @State private var originalEnv: String = ""
    @State private var selectedTab: Int = 0
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showRender = false

    private var hasChanges: Bool {
        composeContent != originalCompose || envContent != originalEnv
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading files...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 0) {
                        Picker("File", selection: $selectedTab) {
                            Text("compose.yml").tag(0)
                            Text(".env").tag(1)
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal)
                        .padding(.vertical, 8)

                        Divider()

                        ZStack(alignment: .bottomTrailing) {
                            if selectedTab == 0 {
                                CodeEditorView(text: $composeContent, language: .yaml)
                            } else {
                                CodeEditorView(text: $envContent, language: .env)
                            }

                            if selectedTab == 0 && !composeContent.isEmpty {
                                Button {
                                    showRender = true
                                } label: {
                                    Image(systemName: "curlybraces")
                                        .font(.title3.weight(.semibold))
                                        .foregroundStyle(.indigo)
                                        .frame(width: 52, height: 52)
                                        .glassEffectCompat(in: .circle)
                                }
                                .padding(.trailing, 16)
                                .padding(.bottom, 16)
                                .accessibilityLabel("Resolve Variables")
                            }
                        }

                        if let errorMessage {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.red)
                                Text(errorMessage)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(.red.opacity(0.1))
                        }
                    }
                }
            }
            .navigationTitle("Project Files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await saveFiles() }
                    } label: {
                        if isSaving { ProgressView().scaleEffect(0.8) }
                        else { Text("Save") }
                    }
                    .disabled(isSaving || !hasChanges)
                }
            }
            .sheet(isPresented: $showRender) {
                RenderComposeView(
                    initialCompose: composeContent,
                    initialEnv: envContent,
                    environmentID: environmentID
                ) { resolved in
                    composeContent = resolved
                }
            }
            .task { await loadFiles() }
        }
    }

    private func loadFiles() async {
        guard let client = manager.client else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let details = try await client.projects.compose(envID: environmentID, projectID: projectID)
            name = details.name
            let loadedCompose = details.composeContent ?? ""
            let loadedEnv = details.envContent ?? ""
            composeContent = loadedCompose
            envContent = loadedEnv
            originalCompose = loadedCompose
            originalEnv = loadedEnv
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func saveFiles() async {
        guard let client = manager.client else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let resolvedName = name.isEmpty ? projectName : name
            let request = UpdateProject(name: resolvedName, composeContent: composeContent, envContent: envContent)
            _ = try await client.projects.update(envID: environmentID, projectID: projectID, request: request)
            dismiss()
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }
}

struct CreateProjectView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutationStore
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let environmentID: EnvironmentID
    let prefilledName: String?
    let prefilledCompose: String?
    let prefilledEnv: String?
    let templateLabel: String?
    let onSuccess: () async -> Void

    @State private var name: String
    @State private var composeContent: String
    @State private var envContent: String
    @State private var templates: [Template] = []
    @State private var selectedTemplateID = ""
    @State private var isLoadingTemplates = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showRender = false

    private static let defaultCompose = "services:\n  app:\n    image: \n    ports:\n      - \"8080:80\"\n"

    init(environmentID: EnvironmentID,
         prefilledName: String? = nil,
         prefilledCompose: String? = nil,
         prefilledEnv: String? = nil,
         templateLabel: String? = nil,
         onSuccess: @escaping () async -> Void) {
        self.environmentID = environmentID
        self.prefilledName = prefilledName
        self.prefilledCompose = prefilledCompose
        self.prefilledEnv = prefilledEnv
        self.templateLabel = templateLabel
        self.onSuccess = onSuccess
        _name = State(initialValue: prefilledName ?? "")
        _composeContent = State(initialValue: prefilledCompose ?? Self.defaultCompose)
        _envContent = State(initialValue: prefilledEnv ?? "")
    }

    private var isPrefilled: Bool { prefilledCompose != nil }

    private var selectedTemplate: Template? {
        templates.first { $0.id == selectedTemplateID }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Project Name") {
                    FormTextField(
                        title: "Name",
                        placeholder: "my-app",
                        text: $name,
                        autocapitalization: .never,
                        autocorrectionDisabled: true,
                        helper: "Use a short stack name that is easy to identify in lists and logs."
                    )
                }

                if isPrefilled {
                    if let label = templateLabel {
                        Section("Template") {
                            HStack {
                                Image(systemName: "doc.text.fill").foregroundStyle(.indigo)
                                Text(label)
                                Spacer()
                                Text("Loaded").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    Section("Template") {
                        if isLoadingTemplates {
                            ProgressView("Loading templates...")
                        } else if templates.isEmpty {
                            Text("No templates available")
                                .foregroundStyle(.secondary)
                        } else {
                            Picker("Use Template", selection: $selectedTemplateID) {
                                Text("Blank").tag("")
                                ForEach(templates) { template in
                                    Text(template.name).tag(template.id)
                                }
                            }
                            .onChange(of: selectedTemplateID) { _, newValue in
                                Task { await applyTemplate(id: newValue) }
                            }

                            if let selectedTemplate {
                                Text(selectedTemplate.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section {
                    CodeEditorView(text: $composeContent, language: .yaml)
                        .frame(height: 220)
                        .listRowInsets(EdgeInsets())
                } header: {
                    HStack {
                        Text("Compose File")
                        Spacer()
                        Button {
                            showRender = true
                        } label: {
                            Label("Variables", systemImage: "curlybraces")
                                .font(.caption)
                        }
                        .disabled(composeContent.isEmpty)
                    }
                }

                Section(".env") {
                    CodeEditorView(text: $envContent, language: .env)
                        .frame(height: 140)
                        .listRowInsets(EdgeInsets())
                }

                if let error = errorMessage {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
            }
            .navigationTitle("Create Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if isLoading {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Button("Create") { Task { await createProject() } }
                            .disabled(name.isEmpty)
                    }
                }
            }
            .sheet(isPresented: $showRender) {
                RenderComposeView(
                    initialCompose: composeContent,
                    initialEnv: envContent,
                    environmentID: environmentID
                ) { resolved in
                    composeContent = resolved
                }
            }
            .task {
                if !isPrefilled {
                    await loadTemplates()
                }
            }
        }
    }

    private func loadTemplates() async {
        guard let client = manager.client else { return }
        isLoadingTemplates = true
        defer { isLoadingTemplates = false }
        do {
            templates = try await client.rest.get("templates/all")
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func applyTemplate(id: String) async {
        guard !id.isEmpty, let client = manager.client else { return }
        do {
            let content: TemplateContent = try await client.rest.get("templates/\(id)/content")
            composeContent = content.content
            envContent = content.envContent
            if name.isEmpty {
                name = content.template.name
                    .lowercased()
                    .replacingOccurrences(of: " ", with: "-")
            }
        } catch { errorMessage = friendlyErrorMessage(error) }
    }

    private func createProject() async {
        guard let client = manager.client else { return }
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            let body: [String: AnyCodable] = [
                "name": AnyCodable(name),
                "composeContent": AnyCodable(composeContent),
                "envContent": AnyCodable(envContent)
            ]
            let path = client.rest.environmentPath(environmentID, "projects")
            let _: ProjectDetails = try await client.rest.post(path, body: body)
            if let cached = manager.cached {
                await cached.invalidate(envID: environmentID, paths: [
                    client.rest.environmentPath(environmentID, "projects") + "*",
                    client.rest.environmentPath(environmentID, "projects/*")
                ])
            }
            mutationStore.markChanged(kind: .projects, envID: environmentID)
            await onSuccess(); dismiss()
        } catch { errorMessage = friendlyErrorMessage(error) }
    }
}
