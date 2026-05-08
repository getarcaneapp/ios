import SwiftUI
import Arcane

struct ProjectDetailView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    let project: Project
    let environmentID: EnvironmentID

    @State private var refreshedProject: Project?
    @State private var composeContent: String = ""
    @State private var isLoading = false
    @State private var isActioning = false
    @State private var actionOutput: [String] = []
    @State private var showLogs = false
    @State private var showCompose = false
    @State private var showDeleteConfirm = false
    @State private var errorMessage: String?

    private var currentProject: Project { refreshedProject ?? project }
    private var isRunning: Bool { currentProject.status.lowercased() == "running" }

    var body: some View {
        List {
            Section {
                projectHeader
            }

            Section("Actions") {
                actionsSection
            }

            if !actionOutput.isEmpty {
                Section("Output") {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(actionOutput.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 200)
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
            ComposeFileView(projectID: project.id, environmentID: environmentID)
        }
        .confirmationDialog("Delete Project", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await deleteProject() } }
        } message: {
            Text("This will permanently delete the project and all its data.")
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
                Task { await performAction(.down) }
            } label: {
                Label("Stop", systemImage: "stop.circle.fill").foregroundStyle(.red)
            }
            .disabled(isActioning)

            Button {
                Task { await performAction(.restart) }
            } label: {
                Label("Restart", systemImage: "arrow.clockwise.circle.fill").foregroundStyle(.orange)
            }
            .disabled(isActioning)

            Button {
                Task { await performAction(.pull) }
            } label: {
                Label("Pull Images", systemImage: "arrow.down.circle.fill").foregroundStyle(.blue)
            }
            .disabled(isActioning)
        } else {
            Button {
                Task { await performAction(.up) }
            } label: {
                Label("Start / Deploy", systemImage: "play.circle.fill").foregroundStyle(.green)
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
    private enum ProjectAction { case up, down, restart, pull }

    private func performAction(_ action: ProjectAction) async {
        guard let client = manager.client else { return }
        isActioning = true; actionOutput = []
        defer { isActioning = false }
        do {
            let suffix: String
            switch action {
            case .up: suffix = "up"
            case .down: suffix = "down"
            case .restart: suffix = "restart"
            case .pull: suffix = "pull"
            }
            let path = client.rest.environmentPath(environmentID, "projects/\(project.id)/\(suffix)")
            let _: DataResponse<String> = try await client.rest.post(path, body: String?.none)
            actionOutput.append("Done.")
            await loadProject()
        } catch {
            errorMessage = error.localizedDescription
            actionOutput.append("Error: \(error.localizedDescription)")
        }
    }

    private func deleteProject() async {
        guard let client = manager.client else { return }
        isActioning = true
        defer { isActioning = false }
        do {
            let path = client.rest.environmentPath(environmentID, "projects/\(project.id)")
            let _: DataResponse<String> = try await client.rest.delete(path)
        } catch { errorMessage = error.localizedDescription }
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
    let environmentID: EnvironmentID

    @State private var composeContent: String = ""
    @State private var envContent: String = ""
    @State private var selectedTab: Int = 0
    @State private var isLoading = false
    @State private var isSaving = false

    private var currentContent: Binding<String> {
        selectedTab == 0 ? $composeContent : $envContent
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

                        if selectedTab == 0 {
                            CodeEditorView(text: $composeContent, language: .yaml)
                        } else {
                            CodeEditorView(text: $envContent, language: .env)
                        }
                    }
                }
            }
            .navigationTitle("Project Files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
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
            .task { await loadFiles() }
        }
    }

    private func loadFiles() async {
        guard let client = manager.client else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let path = client.rest.environmentPath(environmentID, "projects/\(projectID)")
            let project: Project = try await client.rest.get(path)
            composeContent = project.composeContent ?? ""
            envContent = project.envContent ?? ""
        } catch {}
    }

    private func saveFiles() async {
        guard let client = manager.client else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let path = client.rest.environmentPath(environmentID, "projects/\(projectID)/compose")
            let body = ["content": composeContent, "envContent": envContent]
            let _: DataResponse<String> = try await client.rest.post(path, body: body)
            dismiss()
        } catch {}
    }
}

struct CreateProjectView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let environmentID: EnvironmentID
    let onSuccess: () async -> Void

    @State private var name = ""
    @State private var composeContent = "services:\n  app:\n    image: \n    ports:\n      - \"8080:80\"\n"
    @State private var envContent = ""
    @State private var templates: [ComposeTemplate] = []
    @State private var selectedTemplateID = ""
    @State private var isLoadingTemplates = false
    @State private var isLoading = false
    @State private var errorMessage: String?

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

                Section("Compose File") {
                    CodeEditorView(text: $composeContent, language: .yaml)
                        .frame(height: 220)
                        .listRowInsets(EdgeInsets())
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
                    Button("Create") { Task { await createProject() } }
                        .disabled(name.isEmpty || isLoading)
                }
            }
            .task { await loadTemplates() }
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
        } catch { errorMessage = error.localizedDescription }
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
        } catch { errorMessage = error.localizedDescription }
    }
}
