import Arcane
import SwiftUI

struct ProjectsView: View {
    private static let pageSize = 50

    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(PinnedItemsStore.self) private var pinnedStore
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutationStore
    @SwiftUI.Environment(EnvironmentsStore.self) private var environmentsStore
    @SwiftUI.Environment(\.colorScheme) private var colorScheme
    let environmentID: EnvironmentID
    let environmentName: String
    /// All Environments preview: list and act on projects from every enabled environment.
    var allEnvironments = false

    @State private var list = EnvironmentPagedList<ProjectDetails>(pageSize: Self.pageSize)
    @State private var routedProject: EnvironmentItem<ProjectDetails>?
    @State private var routeGeneration = 0
    @State private var router = QuickActionRouter.shared
    @State private var actionErrorMessage: String?
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var showCreateSheet = false
    @State private var createEnvironmentID: EnvironmentID?
    @State private var archivedEnvironmentID: EnvironmentID?
    @State private var showFilterSheet = false
    @State private var pendingDeleteProject: EnvironmentItem<ProjectDetails>?
    @State private var pendingMaintenanceAction: AllEnvironmentsMaintenanceAction?
    @State private var environmentFilter: EnvironmentID?
    @State private var statusFilter = ProjectStatusFilter.all
    @State private var updateFilter = ResourceUpdateFilter.all
    @State private var sortOrder = ListSortOrder.ascending
    @State private var sections: [StableListSection<String, EnvironmentItem<ProjectDetails>>] = []

    @State private var selectedProjectID: String?

    private var projects: [EnvironmentItem<ProjectDetails>] { list.items }

    /// The environments this list covers, known before the first load finishes.
    private var listEnvironments: [ListEnvironment] {
        allEnvironments ? list.environments : [ListEnvironment(id: environmentID, name: nil)]
    }

    private var activeFilterCount: Int {
        var count = statusFilter != .all ? 1 : 0
        if environmentFilter != nil { count += 1 }
        if updateFilter != .all { count += 1 }
        return count
    }

    /// Pinned row IDs, refreshed in `rebuildSections` (not per row render).
    @State private var pinnedIDs: Set<String> = []

    /// Filters + sorts once and partitions in a single pass. Pure — reads the
    /// current inputs and returns the grouped sections without touching state.
    private func computeSections(pinned: Set<String>) -> [StableListSection<String, EnvironmentItem<ProjectDetails>>] {
        let query = debouncedSearchText
        let filtered = projects.filter { project in
            guard environmentFilter == nil || project.environmentID == environmentFilter else { return false }
            let matchesSearch = query.isEmpty || project.displayName.localizedCaseInsensitiveContains(query)
            let status = project.status.lowercased()
            let matchesStatus =
                statusFilter == .all
                || (statusFilter == .running && status == "running")
                || (statusFilter == .stopped && (status == "stopped" || status == "exited"))
                || (statusFilter == .partial && (status == "partial" || status == "partially running"))
            let matchesUpdate = updateFilter.matches(hasUpdate: project.hasAvailableUpdate)
            return matchesSearch && matchesStatus && matchesUpdate
        }
        // displayName trims on every access; compute it once per item, not per comparison.
        .map { ($0.displayName, $0) }
        .sorted { sortOrder.areInIncreasingOrder($0.0, $1.0) }
        .map(\.1)
        var pinnedItems: [EnvironmentItem<ProjectDetails>] = []
        var active: [EnvironmentItem<ProjectDetails>] = []
        var stopped: [EnvironmentItem<ProjectDetails>] = []
        for project in filtered {
            if pinned.contains(project.id) {
                pinnedItems.append(project)
            } else if isStopped(project.value) {
                stopped.append(project)
            } else {
                active.append(project)
            }
        }
        return [
            .init(id: "pinned", title: "Pinned", items: pinnedItems),
            .init(id: "active", title: "Active", items: active),
            .init(id: "stopped", title: "Stopped", items: stopped),
        ]
    }

    /// Refresh the cached `sections`. Called only when an input that affects
    /// grouping actually changes (search settle, sort, filter, pins, or the
    /// source list) — never on every body evaluation.
    private func rebuildSections() {
        let pinned = pinnedStore.pinnedIDs(kind: .project, in: projects)
        if pinned != pinnedIDs { pinnedIDs = pinned }
        sections = computeSections(pinned: pinned)
    }

    private var canBrowseTemplates: Bool {
        manager.permissions.has(Permission.Templates.list, in: nil)
            && manager.permissions.has(Permission.Templates.read, in: nil)
    }

    private var mutationVersion: Int {
        allEnvironments
            ? mutationStore.version(kind: .projects, in: list.environments)
            : mutationStore.version(kind: .projects, envID: environmentID)
    }

    /// Environments the user can create projects in.
    private var createEnvironments: [ListEnvironment] {
        listEnvironments.filter { manager.permissions.has(Permission.Projects.create, in: $0.id) }
    }

    /// Per-section item counts — drives the List's implicit reflow animation so a
    /// programmatic insert/remove animates too.

    private var actionErrorPresented: Binding<Bool> {
        Binding(
            get: { actionErrorMessage != nil },
            set: { if !$0 { actionErrorMessage = nil } }
        )
    }

    @ViewBuilder
    private var content: some View {
        LoadingCrossfade(
            showSkeleton: list.isLoading && projects.isEmpty,
            animatesTransition: false
        ) {
            ArcaneLoadingView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } content: {
            if let error = list.errorMessage, projects.isEmpty {
                ContentUnavailableView {
                    Label("Couldn't Load Projects", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") { Task { await loadProjects() } }
                }
            } else if projects.isEmpty {
                ContentUnavailableView {
                    Label("No Projects", systemImage: "square.stack.3d.up")
                } description: {
                    Text(
                        allEnvironments
                            ? "No Compose projects found in any environment."
                            : "No Compose projects found in this environment.")
                } actions: {
                    if allEnvironments {
                        EnvironmentActionButton(
                            title: "Create Project", systemImage: "plus", environments: createEnvironments
                        ) { environmentID in
                            presentCreateProject(in: environmentID)
                        }
                    } else {
                        Button("Create Project") { presentCreateProject(in: environmentID) }
                    }
                }
            } else {
                projectsList
            }
        }
    }

    private var projectsList: some View {
        List(selection: $selectedProjectID) {
            EnvironmentLoadFailuresSection(failures: list.failedEnvironments) {
                Task { await loadProjects() }
            }
            StableSectionedList(
                sections,
                preferredHeaderAccessorySectionID: "active",
                headerAccessory: { _ in
                    ResourceCountLabel(
                        loadedCount: projects.count,
                        totalCount: list.totalItems,
                        hasMore: list.hasMore
                    )
                }
            ) { project in
                projectLink(project)
            }

            PaginatedListFooter(
                hasMore: list.hasMore,
                loadMoreError: list.loadMoreError,
                onRetry: { Task { await loadMore() } },
                onLoadMore: { Task { await loadMore() } }
            )
        }
        .listStyle(.insetGrouped)

    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if canBrowseTemplates {
            AppToolbarItem(placement: .navigationBarLeading) {
                // Straight into the template browser; registry management is
                // behind its Settings (gear) button.
                NavigationLink(destination: TemplateBrowserView(embedded: true)) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .appAccentToolbarSymbol()
                }
                .accessibilityLabel("Browse Templates")
            }
        }
        AppToolbarItem(placement: .navigationBarTrailing) {
            Button {
                showFilterSheet = true
            } label: {
                Image(
                    systemName: activeFilterCount > 0
                        ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
                )
                .appAccentToolbarSymbol()
            }
            .accessibilityLabel("Filter")
        }
        AppToolbarItem(placement: .navigationBarTrailing) {
            moreOptionsMenu
        }
        if #available(iOS 26, *) {
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
        }
        AppToolbarItem(placement: .navigationBarTrailing) {
            if allEnvironments {
                EnvironmentActionButton(
                    title: "Create Project", systemImage: "plus", environments: createEnvironments
                ) { environmentID in
                    presentCreateProject(in: environmentID)
                }
                .appAccentToolbarSymbol()
                .accessibilityLabel("Create project")
            } else {
                Button {
                    presentCreateProject(in: environmentID)
                } label: {
                    Image(systemName: "plus")
                        .appAccentToolbarSymbol()
                }
                .accessibilityLabel("Create project")
            }
        }
    }

    private var moreOptionsMenu: some View {
        Menu {
            if allEnvironments {
                AllEnvironmentsMaintenanceButtons(action: $pendingMaintenanceAction)
                Divider()
            }
            if allEnvironments {
                EnvironmentActionButton(
                    title: "Archived Projects", systemImage: "archivebox", environments: listEnvironments
                ) { environmentID in
                    archivedEnvironmentID = environmentID
                }
            } else {
                NavigationLink(destination: ArchivedProjectsView(environmentID: environmentID)) {
                    Label("Archived Projects", systemImage: "archivebox")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .appAccentToolbarSymbol()
        }
        .accessibilityLabel("More options")
    }

    private var filterSheetContent: some View {
        NavigationStack {
            Form {
                Section("Sort") {
                    Picker("Sort", selection: $sortOrder) {
                        ForEach(ListSortOrder.allCases) { order in
                            Label(order.title, systemImage: order.systemImage).tag(order)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                EnvironmentFilterSection(environments: list.environments, selection: $environmentFilter)
                Section("Status") {
                    Picker("Status", selection: $statusFilter) {
                        ForEach(ProjectStatusFilter.allCases, id: \.self) { f in
                            Text(f.rawValue).tag(f)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section("Updates") {
                    Picker("Updates", selection: $updateFilter) {
                        ForEach(ResourceUpdateFilter.allCases) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
            .navigationTitle("Filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showFilterSheet = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationContentInteraction(.resizes)
        .presentationDragIndicator(.visible)
    }

    var body: some View {
        content
            .navigationTitle("Projects")
            .navigationBarTitleDisplayMode(.large)
            .searchable(
                text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search projects"
            )
            .toolbar {
                toolbarContent
            }
            // Reappearing (back from a detail) refreshes every loaded page in
            // place; the first appear loads page one.
            .task { await loadProjects(preservingLoadedRange: true) }
            .refreshable { await loadProjects() }
            .debounce(searchText, for: .milliseconds(200), into: $debouncedSearchText)
            .navigationDestination(for: EnvironmentItem<ProjectDetails>.self) { project in
                ProjectDetailView(project: project.value, environmentID: project.environmentID)
                    .onDisappear {
                        selectedProjectID = Self.selectionAfterReturning(
                            selectedProjectID,
                            from: project.id
                        )
                    }
            }
            .sheet(isPresented: $showCreateSheet) {
                CreateProjectView(environmentID: createEnvironmentID ?? environmentID) {}
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showFilterSheet) { filterSheetContent }
            .navigationDestination(item: $routedProject) { project in
                ProjectDetailView(project: project.value, environmentID: project.environmentID)
            }
            .navigationDestination(item: $archivedEnvironmentID) { environmentID in
                ArchivedProjectsView(environmentID: environmentID)
            }
            .allEnvironmentsMaintenanceConfirmation(
                action: $pendingMaintenanceAction, environments: environmentsStore.enabledEnvironments
            )
            .onChange(of: router.pendingRoute, initial: true) { _, _ in
                Task { await consumeProjectRoute() }
            }
            .onChange(of: mutationVersion) { _, _ in
                Task { await loadProjects(preservingLoadedRange: true) }
            }
            .onChange(of: list.revision) { rebuildSections() }
            .onChange(of: debouncedSearchText) { rebuildSections() }
            .onChange(of: environmentFilter) { rebuildSections() }
            .onChange(of: statusFilter) { rebuildSections() }
            .onChange(of: updateFilter) { rebuildSections() }
            .onChange(of: sortOrder) { rebuildSections() }
            .onChange(of: pinnedStore.version) { rebuildSections() }
            .deleteConfirmation(item: $pendingDeleteProject) { project in
                DeleteConfirmationConfig(
                    title: "Delete Project",
                    message: "Remove the project from Arcane, or also remove its files from disk.",
                    icon: "trash",
                    actions: [
                        DeleteConfirmationAction(title: "Delete") {
                            Task { await deleteProject(project, removeFiles: false) }
                        },
                        DeleteConfirmationAction(title: "Delete and Remove Files") {
                            Task { await deleteProject(project, removeFiles: true) }
                        },
                    ]
                )
            }
            .alert(
                "Couldn't Delete Project",
                isPresented: actionErrorPresented
            ) {
                Button("OK", role: .cancel) { actionErrorMessage = nil }
            } message: {
                Text(actionErrorMessage ?? "")
            }
    }

    private func loadProjects(preservingLoadedRange: Bool = false) async {
        guard let client = manager.client else { return }
        let environments = await environmentsStore.listEnvironments(
            environmentID, allEnvironments: allEnvironments, manager: manager)
        await list.reload(
            environments, preservingLoadedRange: preservingLoadedRange, fetch: projectsPage(client: client))
        rebuildSections()
    }

    private func loadMore() async {
        guard let client = manager.client else { return }
        await list.loadMore(fetch: projectsPage(client: client))
        rebuildSections()
    }

    private func projectsPage(client: ArcaneClient) -> EnvironmentPagedList<ProjectDetails>.Fetch {
        { environmentID, start, limit in
            // `PaginatedResponse<ProjectDetails>` is Decodable-only, so we can't
            // route it through the cache layer (which requires Codable). The
            // service call is fast enough that this is fine.
            let query = SearchPaginationSort(start: start, limit: limit)
            let response = try await client.projects.list(envID: environmentID, query: query)
            return ResourcePage(items: response.data, pagination: response.pagination)
        }
    }

    private func listEnvironment(_ id: EnvironmentID) -> ListEnvironment {
        ListEnvironment(id: id, name: allEnvironments ? environmentsStore.displayName(for: id) ?? id.rawValue : nil)
    }

    private func presentCreateProject(in environmentID: EnvironmentID) {
        createEnvironmentID = environmentID
        showCreateSheet = true
    }

    private func projectLink(_ project: EnvironmentItem<ProjectDetails>) -> some View {
        let isPinned = pinnedIDs.contains(project.id)
        return NavigationLink(value: project) {
            ProjectRow(project: project.value, isPinned: isPinned, environmentName: project.environmentName)
                .rowEnvironment(project)
        }
        .contextMenu {
            Button {
                togglePin(project)
            } label: {
                Label(
                    isPinned ? "Unpin" : "Pin",
                    systemImage: isPinned ? "pin.slash.fill" : "pin.fill")
            }
            Button(role: .destructive) {
                pendingDeleteProject = project
            } label: {
                DestructiveLabel(text: "Delete")
            }
            .tint(.red)
        } preview: {
            projectPreview(project)
                .environment(manager)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                togglePinAfterSwipe(project)
            } label: {
                Label(
                    isPinned ? "Unpin" : "Pin",
                    systemImage: isPinned ? "pin.slash.fill" : "pin.fill")
            }
            .tint(.yellow)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                pendingDeleteProject = project
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(.red)
        }
    }

    private func togglePinAfterSwipe(_ project: EnvironmentItem<ProjectDetails>) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            togglePin(project)
        }
    }

    private func togglePin(_ project: EnvironmentItem<ProjectDetails>) {
        HapticsManager.light()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            pinnedStore.togglePin(project, kind: .project)
        }
    }

    private func projectPreview(_ project: EnvironmentItem<ProjectDetails>) -> some View {
        let status = project.status.lowercased()
        let color: Color
        switch status {
        case "running": color = .green
        case "stopped", "exited": color = .red
        case "partial", "partially running": color = .orange
        default: color = .secondary
        }
        var details: [RowPreviewCard.PreviewDetail] = [
            .init(
                icon: "circle.grid.2x2", label: "Services",
                value: "\(project.runningCount)/\(project.serviceCount) running")
        ]
        if let version = project.composeVersion {
            details.append(.init(icon: "doc.text", label: "Compose Version", value: version))
        }
        details.append(.init(icon: "calendar", label: "Created", value: project.createdAt))
        if let environmentName = project.environmentName {
            details.append(.init(icon: "server.rack", label: "Environment", value: environmentName))
        }
        return RowPreviewCard(
            icon: "square.stack.3d.up.fill",
            iconColor: color,
            iconUrl: project.value.themedIconUrl(for: colorScheme),
            title: project.displayName,
            badges: [
                .init(text: project.status.capitalized, color: color)
            ],
            details: details
        )
    }

    private func deleteProject(_ project: EnvironmentItem<ProjectDetails>, removeFiles: Bool) async {
        guard let client = manager.client else { return }
        pendingDeleteProject = nil
        do {
            _ = try await client.projects.destroy(
                envID: project.environmentID,
                projectID: project.value.id,
                options: DestroyProject(removeFiles: removeFiles, removeVolumes: false)
            )
            withAnimation {
                list.update { $0.removeAll { $0.id == project.id } }
                rebuildSections()
            }
            await invalidateProjectCaches(project.environmentID)
            mutationStore.markChanged(kind: .projects, envID: project.environmentID)
            showToast(.success("Project deleted"))
        } catch {
            actionErrorMessage = friendlyErrorMessage(error)
        }
    }

    private func invalidateProjectCaches(_ environmentID: EnvironmentID) async {
        guard let cached = manager.cached, let client = manager.client else { return }
        await cached.invalidate(
            envID: environmentID,
            paths: [
                client.rest.environmentPath(environmentID, "projects") + "*",
                client.rest.environmentPath(environmentID, "projects/*"),
            ])
    }

    private func isStopped(_ project: ProjectDetails) -> Bool {
        let status = project.status.lowercased()
        return status == "stopped" || status == "exited"
    }

    nonisolated static func selectionAfterReturning(
        _ selection: String?,
        from projectID: String
    ) -> String? {
        selection == projectID ? nil : selection
    }
}

struct ProjectRow: View {
    @SwiftUI.Environment(\.colorScheme) private var colorScheme
    let project: ProjectDetails
    var isPinned: Bool = false

    private var statusColor: Color {
        switch project.status.lowercased() {
        case "running": return .green
        case "stopped", "exited": return .red
        case "partial", "partially running": return .orange
        default: return .secondary
        }
    }

    var environmentName: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: project.themedIconUrl(for: colorScheme), size: 36) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 36, height: 36)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(project.displayName)
                        .font(.body)
                        .lineLimit(nil)
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                            .accessibilityHidden(true)
                    }
                }
                EnvironmentLabel(name: environmentName)
            }

            Spacer()

            StatusIcon(status: project.status)
        }

        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        let count = project.serviceCount
        var parts: [String] = [project.displayName]
        if isPinned { parts.append("pinned") }
        parts.append(project.status)
        parts.append("\(count) service\(count == 1 ? "" : "s")")
        if let environmentName { parts.append(environmentName) }
        return parts.joined(separator: ", ")
    }
}

extension ProjectsView {
    fileprivate func consumeProjectRoute() async {
        guard case .authenticated = manager.authState,
            case .project(let envID, let id)? = router.pendingRoute,
            allEnvironments || envID == environmentID.rawValue,
            let client = manager.client
        else { return }
        let routeEnvironmentID = EnvironmentID(rawValue: envID)
        routeGeneration += 1
        let generation = routeGeneration
        let routerGeneration = router.routeGeneration
        let session = manager.cacheSessionIdentity
        router.pendingRoute = nil
        do {
            let project = try await client.projects.get(envID: routeEnvironmentID, projectID: id)
            try Task.checkCancellation()
            guard generation == routeGeneration,
                routerGeneration == router.routeGeneration,
                session == manager.cacheSessionIdentity,
                client.transport === manager.client?.transport,
                manager.acceptsEnvironmentContext(routeEnvironmentID)
            else { return }
            routedProject = EnvironmentItem(project, in: listEnvironment(routeEnvironmentID))
        } catch {
            guard generation == routeGeneration,
                routerGeneration == router.routeGeneration,
                session == manager.cacheSessionIdentity,
                client.transport === manager.client?.transport,
                manager.acceptsEnvironmentContext(routeEnvironmentID)
            else { return }
            showToast(.error(friendlyErrorMessage(error)))
        }
    }
}
