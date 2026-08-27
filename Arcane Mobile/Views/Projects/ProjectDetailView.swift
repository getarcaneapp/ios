import SwiftUI
import Arcane

struct ProjectDetailView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutationStore
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @SwiftUI.Environment(\.colorScheme) private var colorScheme
    @SwiftUI.Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Namespace private var heroTransition
    let project: ProjectDetails
    let environmentID: EnvironmentID

    @State private var refreshedProject: ProjectDetails?
    @State private var isLoading = false
    @State private var isActioning = false
    @State private var actionStatus: String?
    @State private var showDeleteConfirm = false
    @State private var showDeployOptions = false
    @State private var errorMessage: String?
    @State private var runningActionID: String?
    @State private var projectContainers: [ContainerSummary] = []
    @State private var runtimeServices: [RuntimeService] = []
    @State private var workspaceSection: WorkspaceSection = .services
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

    private enum WorkspaceSection: String, CaseIterable, Identifiable {
        case services, logs
        var id: String { rawValue }
        var title: String { rawValue.capitalized }

        var systemImage: String {
            switch self {
            case .services: "shippingbox.fill"
            case .logs: "text.alignleft"
            }
        }

        var tint: Color {
            switch self {
            case .services: .blue
            case .logs: .teal
            }
        }
    }

    private var currentProject: ProjectDetails { refreshedProject ?? project }
    private var isRunning: Bool { currentProject.status.lowercased() == "running" }
    private var hasBuild: Bool { currentProject.hasBuildDirective == true }
    private var containerMutationVersion: Int { mutationStore.version(kind: .containers, envID: environmentID) }
    private var projectMutationVersion: Int { mutationStore.version(kind: .projects, envID: environmentID) }

    var body: some View {
        workspace
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
                .navigationTransition(.zoom(sourceID: container.id, in: heroTransition))
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
        .sheet(isPresented: $showDeployOptions) {
            DeployOptionsSheet(
                serverOrigin: manager.parsedServerURL.flatMap(
                    AppGroup.canonicalServerOrigin(for:)
                ) ?? manager.serverURL,
                environmentID: environmentID
            ) { options in
                startStreamingAction(kind: .up, deployOptions: options)
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

    @ViewBuilder
    private var workspace: some View {
        if horizontalSizeClass == .regular {
            HStack(spacing: 0) {
                servicesTab
                    .frame(maxWidth: .infinity)
                Divider()
                projectLogs
                    .frame(maxWidth: .infinity)
            }
        } else {
            VStack(spacing: 0) {
                ScrollableTabBar(
                    selection: $workspaceSection,
                    options: WorkspaceSection.allCases.map {
                        ScrollableTabOption(
                            $0,
                            title: $0.title,
                            systemImage: $0.systemImage,
                            tint: $0.tint
                        )
                    },
                    accessibilityLabel: "Project workspace sections"
                )

                if workspaceSection == .services {
                    servicesTab
                } else {
                    projectLogs
                }
            }
            .motionAwareAnimation(Motion.state, value: workspaceSection)
        }
    }

    private var projectLogs: some View {
        LogsView(
            title: currentProject.displayName,
            logStream: { timestamps in
                manager.client?.boundedProjectLogs(
                    envID: environmentID,
                    projectID: project.id,
                    timestamps: timestamps
                )
            },
            embedded: true
        )
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

            Section {
                if servicesLoading && runtimeServices.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView().scaleEffect(0.8)
                        Text("Loading services…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if runtimeServices.isEmpty {
                    Text("No services")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(runtimeRows) { row in
                        ProjectRuntimeServiceRow(
                            service: row.service,
                            container: row.container,
                            environmentID: environmentID,
                            transitionNamespace: heroTransition,
                            onAction: { action in
                                Task { await performServiceAction(action, row: row) }
                            }
                        )
                    }
                }
            } header: {
                SectionHeader("Services", systemImage: "cube.box", count: runtimeServices.count)
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
        if manager.supportsPost26MobileFeatures {
            items.append(ActionButtonItem(
                id: "deploy-options",
                title: "Deploy Options",
                systemImage: "slider.horizontal.3",
                tint: .green
            ) {
                showDeployOptions = true
            })
        }
        if hasBuild {
            items.append(ActionButtonItem(id: "build", title: "Build", systemImage: "hammer.fill", tint: .indigo) {
                startStreamingAction(kind: .build)
            })
        }
        items.append(ActionButtonItem(id: "logs", title: "Logs", systemImage: "doc.text.fill", tint: .secondary) {
            workspaceSection = .logs
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

    /// Hands the operation to the app-level store: it owns the stream, the
    /// root sheet, the floating pill, and the Live Activity. Completion bumps
    /// the projects mutation version, which this view already observes to
    /// reload itself.
    private func startStreamingAction(
        kind: DeploymentActionKind,
        deployOptions: DeployOptions? = nil
    ) {
        errorMessage = nil
        actionStatus = nil
        DeploymentActivityStore.shared.start(
            kind: kind,
            envID: environmentID,
            targetID: project.id,
            targetName: currentProject.displayName,
            environmentName: manager.activeEnvironmentName,
            manager: manager,
            mutationStore: mutationStore,
            deployOptions: deployOptions
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
        guard let client = manager.client else { return }
        if refreshedProject == nil { isLoading = true }
        defer { isLoading = false }
        do {
            let path = client.rest.environmentPath(environmentID, "projects/\(project.id)")
            let result: ProjectDetails = try await RemoteDataLimits.boundedAPIResponse(
                client: client,
                path: path,
                as: ProjectDetails.self,
                maximumBytes: RemoteDataLimits.maximumInspectBytes
            )
            refreshedProject = result
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
            let workspace = try await client.projects.workspace(envID: environmentID, projectID: project.id)
            fileBrowserFiles = workspace.files
        } catch {
            if refresh || fileBrowserFiles == nil {
                fileBrowserErrorMessage = friendlyErrorMessage(error)
            }
        }
    }

    /// Loads runtime services first so Compose entries without containers remain
    /// visible, then resolves their IDs against the complete cached container list
    /// to support the standard container-detail navigation.
    private func loadServices(refresh: Bool = false) async {
        guard let client = manager.client, let cached = manager.cached else { return }
        if projectContainers.isEmpty { servicesLoading = true }
        defer { servicesLoading = false }
        do {
            let runtime = try await client.projects.runtime(envID: environmentID, projectID: project.id)
            let services = runtime.runtimeServices ?? []
            runtimeServices = services
            let ids = Set(services.compactMap { $0.containerId }.filter { !$0.isEmpty })

            let path = client.rest.environmentPath(environmentID, "containers")
            if let all: [ContainerSummary] = try await cached.getAllPages(
                path: path, elementType: ContainerSummary.self, policy: .containersList,
                envID: environmentID, refresh: refresh,
                onFresh: { fresh in projectContainers = filterProjectContainers(fresh, ids: ids) },
                fetchPage: { start, limit in
                    let response = try await client.containers.list(
                        envID: environmentID,
                        query: .init(start: start, limit: limit)
                    )
                    return ResourcePage(items: response.data, pagination: response.pagination)
                }
            ) {
                projectContainers = filterProjectContainers(all, ids: ids)
            }
        } catch {
            // Non-fatal: the project info still renders; the Services section just
            // shows its empty state.
        }
    }

    private struct RuntimeRow: Identifiable {
        let service: RuntimeService
        let container: ContainerSummary?
        var id: String { service.name }
    }

    private var runtimeRows: [RuntimeRow] {
        runtimeServices.map { service in
            let container = service.containerId.flatMap { serviceID in
                projectContainers.first { container in
                    container.id == serviceID || container.id.hasPrefix(serviceID) || serviceID.hasPrefix(container.id)
                }
            }
            return RuntimeRow(service: service, container: container)
        }
    }

    private enum ServiceAction { case start, stop, restart, remove }

    private struct ProjectRuntimeServiceRow: View {
        @SwiftUI.Environment(ArcaneClientManager.self) private var manager
        @SwiftUI.Environment(\.colorScheme) private var colorScheme
        let service: RuntimeService
        let container: ContainerSummary?
        let environmentID: EnvironmentID
        let transitionNamespace: Namespace.ID
        let onAction: (ServiceAction) -> Void
        @State private var showRemoveConfirmation = false

        private var isRunning: Bool {
            container?.isRunning == true || service.status.lowercased() == "running"
        }

        private var iconURL: String? {
            colorScheme == .dark
                ? service.iconDarkUrl ?? service.iconUrl
                : service.iconLightUrl ?? service.iconUrl
        }

        var body: some View {
            HStack(spacing: 10) {
                if let container {
                    NavigationLink(value: container) {
                        rowContent
                    }
                    .matchedTransitionSource(id: container.id, in: transitionNamespace)
                } else {
                    rowContent
                }

                if container != nil {
                    Menu {
                        if isRunning {
                            if manager.permissions.has(Permission.Containers.stop, in: environmentID) {
                                Button("Stop", systemImage: "stop.fill") { onAction(.stop) }
                            }
                        } else if manager.permissions.has(Permission.Containers.start, in: environmentID) {
                            Button("Start", systemImage: "play.fill") { onAction(.start) }
                        }
                        if manager.permissions.has(Permission.Projects.restart, in: environmentID) {
                            Button("Restart", systemImage: "arrow.clockwise") { onAction(.restart) }
                        }
                        if manager.permissions.has(Permission.Containers.delete, in: environmentID) {
                            Button(role: .destructive) { showRemoveConfirmation = true } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Actions for \(service.name)")
                }
            }
            .confirmationDialog(
                "Remove \(service.name)?",
                isPresented: $showRemoveConfirmation,
                titleVisibility: .visible
            ) {
                Button("Remove Container", role: .destructive) { onAction(.remove) }
            } message: {
                Text("This removes the service container. The Compose service remains in the project.")
            }
        }

        private var rowContent: some View {
            HStack(spacing: 10) {
                CachedAsyncImage(url: iconURL, size: 36) {
                    Image(systemName: "cube.box.fill")
                        .foregroundStyle(isRunning ? .green : .secondary)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(service.name).font(.subheadline.weight(.semibold))
                        StatusBadge(status: nonEmptyResourceValue(service.health) ?? service.status)
                    }
                    Text(nonEmptyResourceValue(service.image) ?? "Image unavailable")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let ports = service.ports, !ports.isEmpty {
                        Text(ports.joined(separator: ", "))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if container == nil {
                        Text("Container not created")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(.rect)
        }

    }

    private func performServiceAction(_ action: ServiceAction, row: RuntimeRow) async {
        guard let client = manager.client else { return }
        do {
            switch action {
            case .start:
                guard let id = row.container?.id else { return }
                _ = try await client.containers.start(envID: environmentID, id: id)
            case .stop:
                guard let id = row.container?.id else { return }
                _ = try await client.containers.stop(envID: environmentID, id: id)
            case .restart:
                _ = try await client.projects.restart(
                    envID: environmentID,
                    projectID: project.id,
                    services: [row.service.name]
                )
            case .remove:
                guard let id = row.container?.id else { return }
                _ = try await client.containers.delete(envID: environmentID, id: id, force: true)
            }
            await invalidateProjectCaches()
            mutationStore.markChanged(kind: .containers, envID: environmentID)
            await loadServices(refresh: true)
            showToast(.success("Service action complete"))
        } catch {
            showToast(.error(friendlyErrorMessage(error)))
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

struct ProjectDeployOptionsDraft: Equatable {
    var pullPolicy: String
    var forceRecreate: Bool
    var recreateVolumes = false

    mutating func consume() -> DeployOptions {
        defer { recreateVolumes = false }
        return DeployOptions(
            pullPolicy: pullPolicy,
            forceRecreate: forceRecreate,
            recreateVolumes: recreateVolumes
        )
    }
}

private struct DeployOptionsSheet: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss

    let serverOrigin: String
    let environmentID: EnvironmentID
    let deploy: (DeployOptions) -> Void

    @State private var draft: ProjectDeployOptionsDraft
    @State private var showsVolumeWarning = false

    init(
        serverOrigin: String,
        environmentID: EnvironmentID,
        deploy: @escaping (DeployOptions) -> Void
    ) {
        self.serverOrigin = serverOrigin
        self.environmentID = environmentID
        self.deploy = deploy
        let stored = ProjectDeployOptionsPreferences.load(
            serverOrigin: serverOrigin,
            environmentID: environmentID
        )
        _draft = State(initialValue: ProjectDeployOptionsDraft(
            pullPolicy: stored.pullPolicy,
            forceRecreate: stored.forceRecreate
        ))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Image Pull Policy") {
                    Picker("Pull Images", selection: $draft.pullPolicy) {
                        Text("If Missing").tag("missing")
                        Text("Always").tag("always")
                        Text("Never").tag("never")
                    }
                }

                Section {
                    Toggle("Force Recreation", isOn: $draft.forceRecreate)
                    Toggle("Recreate Volumes", isOn: $draft.recreateVolumes)
                } header: {
                    Text("Container Recreation")
                } footer: {
                    Text("Recreating volumes permanently deletes their current data.")
                }
            }
            .navigationTitle("Deploy Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Deploy") {
                        if draft.recreateVolumes {
                            showsVolumeWarning = true
                        } else {
                            beginDeploy()
                        }
                    }
                }
            }
            .confirmationDialog(
                "Recreate Volumes?",
                isPresented: $showsVolumeWarning,
                titleVisibility: .visible
            ) {
                Button("Deploy and Delete Volume Data", role: .destructive) {
                    beginDeploy()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Existing project volume data will be permanently lost.")
            }
        }
    }

    private func beginDeploy() {
        let options = draft.consume()
        ProjectDeployOptionsPreferences.save(
            pullPolicy: draft.pullPolicy,
            forceRecreate: draft.forceRecreate,
            serverOrigin: serverOrigin,
            environmentID: environmentID
        )
        deploy(options)
        dismiss()
    }
}

private enum ProjectDeployOptionsPreferences {
    struct Values {
        let pullPolicy: String
        let forceRecreate: Bool
    }

    static func load(serverOrigin: String, environmentID: EnvironmentID) -> Values {
        let defaults = UserDefaults.standard
        let key = keyPrefix(serverOrigin: serverOrigin, environmentID: environmentID)
        return Values(
            pullPolicy: defaults.string(forKey: "\(key).pullPolicy") ?? "missing",
            forceRecreate: defaults.bool(forKey: "\(key).forceRecreate")
        )
    }

    static func save(
        pullPolicy: String,
        forceRecreate: Bool,
        serverOrigin: String,
        environmentID: EnvironmentID
    ) {
        let defaults = UserDefaults.standard
        let key = keyPrefix(serverOrigin: serverOrigin, environmentID: environmentID)
        defaults.set(pullPolicy, forKey: "\(key).pullPolicy")
        defaults.set(forceRecreate, forKey: "\(key).forceRecreate")
    }

    private static func keyPrefix(
        serverOrigin: String,
        environmentID: EnvironmentID
    ) -> String {
        let encodedOrigin = Data(serverOrigin.utf8).base64EncodedString()
        return "arcane.deployOptions.\(encodedOrigin).\(environmentID.rawValue)"
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

    private var canBrowseTemplates: Bool {
        manager.permissions.has(Permission.Templates.list, in: nil)
            && manager.permissions.has(Permission.Templates.read, in: nil)
    }

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
                } else if canBrowseTemplates {
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
                if !isPrefilled, canBrowseTemplates {
                    await loadTemplates()
                }
            }
        }
    }

    private func loadTemplates() async {
        guard canBrowseTemplates, let client = manager.client else { return }
        isLoadingTemplates = true
        defer { isLoadingTemplates = false }
        do {
            templates = try await client.templates.listAll()
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func applyTemplate(id: String) async {
        guard canBrowseTemplates, !id.isEmpty, let client = manager.client else { return }
        do {
            let escapedID = ArcaneAPIHelpers.escapedPathComponent(id)
            let content = try await RemoteDataLimits.boundedAPIResponse(
                client: client,
                path: "templates/\(escapedID)/content",
                as: TemplateContent.self,
                maximumBytes: RemoteDataLimits.maximumTemplateBytes
            )
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
