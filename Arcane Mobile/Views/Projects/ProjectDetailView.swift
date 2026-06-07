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
    @State private var streamingAction: StreamingAction?
    @State private var errorMessage: String?
    @State private var runningActionID: String?
    @State private var selectedTab: DetailTab = .services
    @State private var projectContainers: [ContainerSummary] = []
    @State private var servicesLoading = false

    private var currentProject: ProjectDetails { refreshedProject ?? project }
    private var isRunning: Bool { currentProject.status.lowercased() == "running" }
    private var hasBuild: Bool { currentProject.hasBuildDirective == true }
    private var containerMutationVersion: Int { mutationStore.version(kind: .containers, envID: environmentID) }

    private enum DetailTab: String, CaseIterable, Identifiable {
        case services, configuration
        var id: String { rawValue }
        var title: String {
            switch self {
            case .services: return "Services"
            case .configuration: return "Configuration"
            }
        }
    }

    struct StreamingAction: Identifiable {
        let id = UUID()
        let title: String
        let path: String
        let method: String
        let body: Data?
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $selectedTab) {
                ForEach(DetailTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 4)

            // Both tabs stay mounted (crossfade rather than insert/remove) so the
            // editor keeps unsaved edits when the user flips to Services and back.
            ZStack {
                servicesTab
                    .opacity(selectedTab == .services ? 1 : 0)
                    .allowsHitTesting(selectedTab == .services)
                    .accessibilityHidden(selectedTab != .services)

                ProjectConfigurationTab(
                    projectID: project.id,
                    projectName: currentProject.name,
                    environmentID: environmentID,
                    isActive: selectedTab == .configuration
                ) {
                    await invalidateProjectCaches()
                    mutationStore.markChanged(kind: .projects, envID: environmentID)
                    await loadProject(refresh: true)
                    await loadServices(refresh: true)
                }
                .opacity(selectedTab == .configuration ? 1 : 0)
                .allowsHitTesting(selectedTab == .configuration)
                .accessibilityHidden(selectedTab != .configuration)
            }
            .motionAwareAnimation(Motion.state, value: selectedTab)
        }
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
        .refreshable {
            await loadProject(refresh: true)
            await loadServices(refresh: true)
        }
        .onChange(of: containerMutationVersion) { _, _ in
            Task { await loadServices(refresh: true) }
        }
        .navigationDestination(for: ContainerSummary.self) { container in
            ContainerDetailView(container: container, environmentID: environmentID)
                .navigationTransition(.zoom(sourceID: container.id, in: heroTransition))
        }
        .sheet(isPresented: $showLogs) {
            LogsView(
                title: currentProject.displayName,
                logStream: manager.client?.projects.logs(envID: environmentID, projectID: project.id)
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
                await loadServices(refresh: true)
                HapticsManager.success()
                ReviewPrompter.shared.recordSuccess()
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
        .padding(.vertical, 4)
    }

    /// Formats the project's ISO-8601 `createdAt`, tolerating both fractional and
    /// whole-second timestamps; falls back to the raw string.
    private func headerDate(_ iso: String) -> String {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = withFraction.date(from: iso) ?? plain.date(from: iso) {
            return date.formatted(date: .abbreviated, time: .omitted)
        }
        return iso
    }

    /// State-aware centre action: Deploy when stopped, Stop when running.
    private var morphPrimary: ActionButtonItem {
        if isRunning {
            return ActionButtonItem(id: "stop", title: "Stop", systemImage: "stop.fill", tint: .red, role: .destructive) {
                Task { await performSimpleAction(suffix: "down", label: "Stopping", actionID: "stop") }
            }
        } else {
            return ActionButtonItem(id: "start", title: "Deploy", systemImage: "play.fill", tint: .green) {
                startStreamingAction(suffix: "up", title: "Deploy \(currentProject.displayName)")
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
            startStreamingAction(suffix: "redeploy", title: "Redeploy \(currentProject.displayName)")
        })
        items.append(ActionButtonItem(id: "pull", title: "Pull", systemImage: "arrow.down", tint: .accentColor) {
            startStreamingAction(suffix: "pull", title: "Pull Images")
        })
        return items
    }

    private var morphOverflow: [ActionButtonItem] {
        var items: [ActionButtonItem] = []
        if hasBuild {
            items.append(ActionButtonItem(id: "build", title: "Build", systemImage: "hammer.fill", tint: .indigo) {
                startStreamingAction(suffix: "build", title: "Build Images")
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
        // `role: nil` + red tint: keeps the view's bespoke two-option delete
        // alert (Delete / Delete and Remove Files) while still reading as
        // destructive in the overflow menu.
        items.append(ActionButtonItem(id: "delete", title: "Delete Project", systemImage: "trash", tint: .red) {
            showDeleteConfirm = true
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

/// The project's compose / `.env` editor, embedded as the "Configuration" tab of
/// `ProjectDetailView`. `isActive` drives a lazy first load and gates the Save
/// toolbar item so it only appears while this tab is showing; the view stays
/// mounted across tab switches so in-progress edits are preserved.
struct ProjectConfigurationTab: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    let projectID: String
    let projectName: String
    let environmentID: EnvironmentID
    let isActive: Bool
    var onSaved: () async -> Void = {}

    @State private var name: String = ""
    @State private var composeContent: String = ""
    @State private var envContent: String = ""
    @State private var originalCompose: String = ""
    @State private var originalEnv: String = ""
    @State private var selectedFile: Int = 0
    @State private var hasLoaded = false
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showRender = false

    private var hasChanges: Bool {
        composeContent != originalCompose || envContent != originalEnv
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading files...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    Picker("File", selection: $selectedFile) {
                        Text("compose.yml").tag(0)
                        Text(".env").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.vertical, 8)

                    Divider()

                    ZStack(alignment: .bottomTrailing) {
                        if selectedFile == 0 {
                            CodeEditorView(text: $composeContent, language: .yaml)
                        } else {
                            CodeEditorView(text: $envContent, language: .env)
                        }

                        if selectedFile == 0 && !composeContent.isEmpty {
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
        .toolbar {
            if isActive {
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
        .task(id: isActive) {
            if isActive && !hasLoaded {
                hasLoaded = true
                await loadFiles()
            }
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
            originalCompose = composeContent
            originalEnv = envContent
            showToast(.success("Saved"))
            await onSaved()
        } catch {
            errorMessage = friendlyErrorMessage(error)
            showToast(.error("Couldn't save"))
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
