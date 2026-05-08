import SwiftUI
import Arcane

struct ProjectDetailView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let project: Project
    let environmentID: EnvironmentID

    @State private var refreshedProject: Project?
    @State private var isLoading = false
    @State private var isActioning = false
    @State private var actionStatus: String?
    @State private var showLogs = false
    @State private var showCompose = false
    @State private var showDeleteConfirm = false
    @State private var streamingAction: StreamingAction?
    @State private var errorMessage: String?

    private var currentProject: Project { refreshedProject ?? project }
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

            Section("Actions") {
                actionsSection
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
        .navigationTitle(currentProject.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack {
                    Button { showCompose = true } label: {
                        Image(systemName: "doc.text")
                    }
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                    .disabled(isActioning)
                }
            }
        }
        .task { await loadProject() }
        .refreshable { await loadProject() }
        .sheet(isPresented: $showLogs) {
            LogsView(
                title: currentProject.displayName,
                logStream: manager.client?.projects.logs(envID: environmentID, id: project.id)
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
                await loadProject()
            }
        }
        .confirmationDialog("Delete Project", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await deleteProject() } }
        } message: {
            Text("This removes the project from Arcane. Files on disk are preserved.")
        }
    }

    private var projectHeader: some View {
        HStack(spacing: 16) {
            CachedAsyncImage(url: currentProject.iconUrl, size: 56) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.title)
                    .foregroundStyle(.indigo)
                    .frame(width: 56, height: 56)
                    .glassEffect(.regular, in: .circle)
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

    @ViewBuilder
    private var actionsSection: some View {
        if isRunning {
            Button {
                Task { await performSimpleAction(suffix: "down", label: "Stopping") }
            } label: {
                Label("Stop", systemImage: "stop.circle.fill").foregroundStyle(.red)
            }
            .disabled(isActioning)

            Button {
                Task { await performSimpleAction(suffix: "restart", label: "Restarting") }
            } label: {
                Label("Restart", systemImage: "arrow.clockwise.circle.fill").foregroundStyle(.orange)
            }
            .disabled(isActioning)
        } else {
            Button {
                startStreamingAction(suffix: "up", title: "Deploy \(currentProject.displayName)")
            } label: {
                Label("Start / Deploy", systemImage: "play.circle.fill").foregroundStyle(.green)
            }
            .disabled(isActioning)
        }

        Button {
            startStreamingAction(suffix: "redeploy", title: "Redeploy \(currentProject.displayName)")
        } label: {
            Label("Redeploy", systemImage: "arrow.triangle.2.circlepath.circle.fill").foregroundStyle(.purple)
        }
        .disabled(isActioning)

        Button {
            startStreamingAction(suffix: "pull", title: "Pull Images")
        } label: {
            Label("Pull Images", systemImage: "arrow.down.circle.fill").foregroundStyle(.blue)
        }
        .disabled(isActioning)

        if hasBuild {
            Button {
                startStreamingAction(suffix: "build", title: "Build Images")
            } label: {
                Label("Build Images", systemImage: "hammer.circle.fill").foregroundStyle(.indigo)
            }
            .disabled(isActioning)
        }

        Button {
            showLogs = true
        } label: {
            Label("View Logs", systemImage: "doc.text.fill")
        }
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

    private func performSimpleAction(suffix: String, label: String) async {
        guard let client = manager.client else { return }
        isActioning = true
        actionStatus = "\(label)…"
        errorMessage = nil
        defer { isActioning = false }
        do {
            let path = client.rest.environmentPath(environmentID, "projects/\(project.id)/\(suffix)")
            let _: DataResponse<String> = try await client.rest.post(path, body: String?.none)
            actionStatus = "Done."
            await loadProject()
        } catch {
            errorMessage = friendlyErrorMessage(error)
            actionStatus = nil
        }
    }

    private func deleteProject() async {
        guard let client = manager.client else { return }
        isActioning = true
        actionStatus = "Deleting…"
        errorMessage = nil
        defer { isActioning = false }
        do {
            let path = client.rest.environmentPath(environmentID, "projects/\(project.id)/destroy")
            let _: DataResponse<String> = try await client.rest.delete(path)
            dismiss()
        } catch {
            errorMessage = friendlyErrorMessage(error)
            actionStatus = nil
        }
    }

    private func loadProject() async {
        guard let client = manager.client else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let path = client.rest.environmentPath(environmentID, "projects/\(project.id)")
            refreshedProject = try await client.rest.get(path)
        } catch {}
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
    @State private var selectedTab: Int = 0
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showRender = false

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

                        if selectedTab == 0 {
                            CodeEditorView(text: $composeContent, language: .yaml)
                        } else {
                            CodeEditorView(text: $envContent, language: .env)
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
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showRender = true
                    } label: {
                        Image(systemName: "curlybraces")
                    }
                    .disabled(selectedTab != 0 || composeContent.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await saveFiles() }
                    } label: {
                        if isSaving { ProgressView().scaleEffect(0.8) }
                        else { Text("Save") }
                    }
                    .disabled(isSaving)
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
            let path = client.rest.environmentPath(environmentID, "projects/\(projectID)")
            let project: Project = try await client.rest.get(path)
            name = project.name
            composeContent = project.composeContent ?? ""
            envContent = project.envContent ?? ""
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
            let body: [String: AnyCodable] = [
                "name": AnyCodable(resolvedName),
                "composeContent": AnyCodable(composeContent),
                "envContent": AnyCodable(envContent)
            ]
            let path = client.rest.environmentPath(environmentID, "projects/\(projectID)")
            let _: Project = try await client.rest.put(path, body: body)
            dismiss()
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }
}

struct CreateProjectView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
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
    @State private var templates: [ComposeTemplate] = []
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

    private var selectedTemplate: ComposeTemplate? {
        templates.first { $0.id == selectedTemplateID }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Project Name") {
                    TextField("my-app", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
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
        } catch {}
    }

    private func applyTemplate(id: String) async {
        guard !id.isEmpty, let client = manager.client else { return }
        do {
            let content: ComposeTemplateContent = try await client.rest.get("templates/\(id)/content")
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
            let _: Project = try await client.rest.post(path, body: body)
            await onSuccess(); dismiss()
        } catch { errorMessage = friendlyErrorMessage(error) }
    }
}
