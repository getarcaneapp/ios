import SwiftUI
import Arcane

struct ProjectDetailView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutationStore
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @SwiftUI.Environment(\.colorScheme) private var colorScheme
    @Namespace private var heroTransition
    let project: ProjectDetails
    let environmentID: EnvironmentID

    @State private var refreshedProject: ProjectDetails?
    @State private var isLoading = false
    @State private var isActioning = false
    @State private var actionStatus: String?
    @State private var showLogs = false
    @State private var showDeleteConfirm = false
    @State private var showAskAI = false
    @State private var errorMessage: String?
    @State private var runningActionID: String?
    @State private var projectContainers: [ContainerSummary] = []
    @State private var servicesLoading = false
    @State private var fileBrowserFiles: [ProjectFile]?
    @State private var fileBrowserLoading = false
    @State private var fileBrowserErrorMessage: String?
    /// Drives the Project Files workspace as a modal sheet (over the tab bar)
    /// rather than a push (which leaves the tab bar visible). The UUID gives each
    /// tap a fresh identity so re-opening always re-presents.
    @State private var filesSheet: FilesSheetRequest?

    private struct FilesSheetRequest: Identifiable {
        let id = UUID()
        let selection: ProjectFilesWorkspaceDestination
    }

    private var currentProject: ProjectDetails { refreshedProject ?? project }
    private var isRunning: Bool { currentProject.status.lowercased() == "running" }
    private var hasBuild: Bool { currentProject.hasBuildDirective == true }
    private var containerMutationVersion: Int { mutationStore.version(kind: .containers, envID: environmentID) }
    private var projectMutationVersion: Int { mutationStore.version(kind: .projects, envID: environmentID) }

    var body: some View {
        servicesTab
        .morphingActions(
            primary: morphPrimary,
            inline: morphInline,
            overflow: morphOverflow,
            runningItemID: runningActionID,
            isDisabled: isActioning,
            resourceName: currentProject.displayName
        )
        .navigationTitle(currentProject.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadProject() }
        .task { await loadServices() }
        .task { await loadProjectFiles() }
        .refreshable {
            await loadProject(refresh: true)
            await loadServices(refresh: true)
            await loadProjectFiles(refresh: true)
        }
        .onChange(of: containerMutationVersion) { _, _ in
            Task { await loadServices(refresh: true) }
        }
        .onChange(of: projectMutationVersion) { _, _ in
            Task {
                await loadProject(refresh: true)
                await loadServices(refresh: true)
                await loadProjectFiles(refresh: true)
            }
        }
        .navigationDestination(for: ContainerSummary.self) { container in
            ContainerDetailView(container: container, environmentID: environmentID)
                    .pageEntranceFromTop()
        }
        .sheet(isPresented: $showLogs) {
            LogsView(
                title: currentProject.displayName,
                logStream: manager.client?.projects.logs(envID: environmentID, projectID: project.id)
            )
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showAskAI) {
            if #available(iOS 26, *) {
                NavigationStack {
                    AIAssistantView(seed: .project(id: project.id, name: currentProject.displayName))
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("Done") { showAskAI = false }
                            }
                        }
                }
                .presentationDragIndicator(.visible)
            }
        }
        .sheet(item: $filesSheet) { request in
            NavigationStack {
                ProjectFilesWorkspaceView(
                    project: currentProject,
                    environmentID: environmentID,
                    initialSelection: request.selection
                )
            }
        }
        .deleteConfirmation(isPresented: $showDeleteConfirm, config: DeleteConfirmationConfig(
            title: "Delete Project",
            message: "Remove the project from Arcane, or also remove its files from disk.",
            icon: "trash",
            actions: [
                DeleteConfirmationAction(title: "Delete") {
                    Task { await deleteProject(removeFiles: false) }
                },
                DeleteConfirmationAction(title: "Delete and Remove Files") {
                    Task { await deleteProject(removeFiles: true) }
                }
            ]
        ))
    }

    private var servicesTab: some View {
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

            projectFilesSection

            Section("Services") {
                if servicesLoading && projectContainers.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView().scaleEffect(0.8)
                        Text("Loading services…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if projectContainers.isEmpty {
                    Text("No running services")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(projectContainers) { container in
                        NavigationLink(value: container) {
                            ContainerRow(container: container)
                        }
                        .matchedTransitionSource(id: container.id, in: heroTransition)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .softTopScrollEdgeEffectCompat()
    }

    private var projectHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                CachedAsyncImage(url: currentProject.themedIconUrl(for: colorScheme), size: 56) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.title)
                        .foregroundStyle(.indigo)
                        .frame(width: 56, height: 56)
                        .glassEffectCompat(in: .circle)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(currentProject.displayName)
                        .font(.headline)
                    let count = currentProject.serviceCount
                    Text("\(count) service\(count == 1 ? "" : "s") · \(currentProject.runningCount) running")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(headerDate(currentProject.createdAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let version = currentProject.composeVersion {
                        Text("Compose \(version)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    StatusBadge(status: currentProject.status)
                        .padding(.top, 2)
                }
            }

        }
        .padding(.vertical, 4)
    }

    private var projectFilesSection: some View {
        Section("Files") {
            Button {
                filesSheet = FilesSheetRequest(selection: .compose)
            } label: {
                ProjectFileBrowserRow(
                    name: projectComposeFileName,
                    detail: "Compose definition",
                    systemImage: "doc.text",
                    isDirectory: false,
                    showsDisclosure: true
                )
            }
            .buttonStyle(.plain)

            Button {
                filesSheet = FilesSheetRequest(selection: .env)
            } label: {
                ProjectFileBrowserRow(
                    name: ".env",
                    detail: "Environment variables",
                    systemImage: "key.horizontal",
                    isDirectory: false,
                    showsDisclosure: true
                )
            }
            .buttonStyle(.plain)

            if fileBrowserLoading && fileBrowserFiles == nil {
                HStack(spacing: 10) {
                    ProgressView().scaleEffect(0.8)
                    Text("Loading files...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let fileBrowserErrorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Label(fileBrowserErrorMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Button {
                        Task { await loadProjectFiles(refresh: true) }
                    } label: {
                        Label("Reload files", systemImage: "arrow.clockwise")
                    }
                    .font(.caption.weight(.semibold))
                }
            } else {
                ForEach(pinnedFileBrowserEntries) { entry in
                    Button {
                        filesSheet = FilesSheetRequest(selection: .managedFile(entry.relativePath))
                    } label: {
                        ProjectFileBrowserRow(
                            name: entry.name,
                            detail: "Compose override",
                            systemImage: "doc.text",
                            isDirectory: false,
                            showsDisclosure: true
                        )
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    filesSheet = FilesSheetRequest(selection: .files)
                } label: {
                    ProjectFileBrowserRow(
                        name: "Browse Files",
                        detail: "Add or manage custom files",
                        systemImage: "folder.badge.plus",
                        isDirectory: true,
                        showsDisclosure: true
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var projectComposeFileName: String {
        guard let value = currentProject.composeFileName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return "compose.yml"
        }
        return value
    }

    private var fileBrowserEntries: [ManagedProjectFileEntry] {
        ProjectFileWorkspaceHelpers.apply(projectFiles: fileBrowserFiles ?? currentProject.projectFiles ?? [], changes: [])
    }

    /// Only compose override files earn a pinned row next to compose/.env;
    /// everything else is reached through Browse Files.
    private var pinnedFileBrowserEntries: [ManagedProjectFileEntry] {
        let overrideNames: Set<String> = [
            "compose.override.yaml",
            "compose.override.yml",
            "docker-compose.override.yaml",
            "docker-compose.override.yml"
        ]
        return fileBrowserEntries.filter { entry in
            ProjectFileWorkspaceHelpers.parentPath(entry.relativePath).isEmpty
                && !entry.isDirectory
                && overrideNames.contains(entry.name.lowercased())
        }
    }

    /// Formats the project's ISO-8601 `createdAt`, tolerating both fractional and
    /// whole-second timestamps; falls back to the raw string.
    private func headerDate(_ iso: String) -> String {
        ArcaneDateFormatting.formattedISO8601(iso, date: .abbreviated, time: .omitted)
    }

    /// State-aware centre action: Deploy when stopped, Stop when running.
    private var morphPrimary: ActionButtonItem {
        if isRunning {
            return ActionButtonItem(id: "stop", title: "Stop", systemImage: "stop.fill", tint: .red, role: .destructive) {
                Task { await performSimpleAction(suffix: "down", label: "Stopping", actionID: "stop") }
            }
        } else {
            return ActionButtonItem(id: "start", title: "Deploy", systemImage: "play.fill", tint: .green) {
                startStreamingAction(kind: .up)
            }
        }
    }

    private var morphInline: [ActionButtonItem] {
        var items: [ActionButtonItem] = []
        if isRunning {
            items.append(ActionButtonItem(id: "restart", title: "Restart", systemImage: "arrow.clockwise", tint: .orange) {
                Task { await performSimpleAction(suffix: "restart", label: "Restarting", actionID: "restart") }
            })
        }
        items.append(ActionButtonItem(id: "redeploy", title: "Redeploy", systemImage: "arrow.triangle.2.circlepath", tint: .purple) {
            startStreamingAction(kind: .redeploy)
        })
        items.append(ActionButtonItem(id: "pull", title: "Pull", systemImage: "arrow.down", tint: .accentColor) {
            startStreamingAction(kind: .pull)
        })
        return items
    }

    private var morphOverflow: [ActionButtonItem] {
        var items: [ActionButtonItem] = []
        if hasBuild {
            items.append(ActionButtonItem(id: "build", title: "Build", systemImage: "hammer.fill", tint: .indigo) {
                startStreamingAction(kind: .build)
            })
        }
        items.append(ActionButtonItem(id: "logs", title: "Logs", systemImage: "doc.text.fill", tint: .secondary) {
            showLogs = true
        })
        if currentProject.isArchived {
            items.append(ActionButtonItem(id: "unarchive", title: "Unarchive Project", systemImage: "tray.and.arrow.up", tint: .accentColor) {
                Task { await unarchiveProject() }
            })
        } else {
            items.append(ActionButtonItem(id: "archive", title: "Archive Project", systemImage: "archivebox", tint: .accentColor) {
                Task { await archiveProject() }
            })
        }
        if AIAvailability.isReady {
            items.append(ActionButtonItem(id: "ask-ai", title: "Ask AI", systemImage: "sparkles", tint: .purple) {
                showAskAI = true
            })
        }
        // `role: nil` + red tint: keeps the view's bespoke two-option delete
        // alert (Delete / Delete and Remove Files) while still reading as
        // destructive in the overflow menu.
        items.append(ActionButtonItem(id: "delete", title: "Delete Project", systemImage: "trash", tint: .red) {
            showDeleteConfirm = true
        })
        return items
    }

    // MARK: - Actions

    /// Hands the operation to the app-level store: it owns the stream, the
    /// root sheet, the floating pill, and the Live Activity. Completion bumps
    /// the projects mutation version, which this view already observes to
    /// reload itself.
    private func startStreamingAction(kind: DeploymentActionKind) {
        errorMessage = nil
        actionStatus = nil
        DeploymentActivityStore.shared.start(
            kind: kind,
            envID: environmentID,
            targetID: project.id,
            targetName: currentProject.displayName,
            environmentName: manager.activeEnvironmentName,
            manager: manager,
            mutationStore: mutationStore
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
            await loadServices(refresh: true)
            showToast(.success("Action complete"))
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

    private func loadProjectFiles(refresh: Bool = false) async {
        guard let client = manager.client else { return }
        if fileBrowserFiles == nil { fileBrowserLoading = true }
        fileBrowserErrorMessage = nil
        defer { fileBrowserLoading = false }
        do {
            let files = try await client.projects.files(envID: environmentID, projectID: project.id)
            fileBrowserFiles = files.projectFiles ?? []
        } catch {
            if refresh || fileBrowserFiles == nil {
                fileBrowserErrorMessage = friendlyErrorMessage(error)
            }
        }
    }

    /// Loads the project's containers for the Services tab. The project `runtime`
    /// endpoint is the authoritative source of which container IDs belong to this
    /// project; we intersect that set with the (cache-warm) environment container
    /// list so the rows reuse `ContainerRow` + the standard container navigation.
    private func loadServices(refresh: Bool = false) async {
        guard let client = manager.client, let cached = manager.cached else { return }
        if projectContainers.isEmpty { servicesLoading = true }
        defer { servicesLoading = false }
        do {
            let runtime = try await client.projects.runtime(envID: environmentID, projectID: project.id)
            let ids = Set((runtime.runtimeServices ?? []).compactMap { $0.containerId }.filter { !$0.isEmpty })

            let path = client.rest.environmentPath(environmentID, "containers")
            if let all: [ContainerSummary] = try await cached.getList(
                path, elementType: ContainerSummary.self, policy: .containersList,
                envID: environmentID, refresh: refresh,
                onFresh: { fresh in projectContainers = filterProjectContainers(fresh, ids: ids) }
            ) {
                projectContainers = filterProjectContainers(all, ids: ids)
            }
        } catch {
            // Non-fatal: the project info still renders; the Services section just
            // shows its empty state.
        }
    }

    /// Keeps the environment containers that belong to this project, tolerating
    /// short/long Docker ID forms, sorted running-first then by name.
    private func filterProjectContainers(_ all: [ContainerSummary], ids: Set<String>) -> [ContainerSummary] {
        all.filter { container in
            ids.contains { id in
                container.id == id || container.id.hasPrefix(id) || id.hasPrefix(container.id)
            }
        }
        .sorted { lhs, rhs in
            if lhs.isRunning != rhs.isRunning { return lhs.isRunning }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
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
                .presentationDragIndicator(.visible)
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
