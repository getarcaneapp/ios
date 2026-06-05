import SwiftUI
import Arcane

struct ProjectsView: View {
    private static let pageSize = 50

    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(PinnedItemsStore.self) private var pinnedStore
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutationStore
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    let environmentID: EnvironmentID
    let environmentName: String

    @Namespace private var heroTransition

    @State private var projects: [ProjectDetails] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var actionErrorMessage: String?
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var showCreateSheet = false
    @State private var showFilterSheet = false
    @State private var pendingDeleteProject: ProjectDetails?
    @State private var loadGeneration = 0
    @State private var currentPage = 1
    @State private var hasMore = false
    @State private var isLoadingMore = false
    @State private var statusFilter = ProjectStatusFilter.all
    @State private var updateFilter = ResourceUpdateFilter.all
    @State private var sortOrder = ListSortOrder.ascending
    @State private var sections: [StableListSection<String, ProjectDetails>] = []

    private enum ProjectStatusFilter: String, CaseIterable {
        case all = "All", running = "Running", stopped = "Stopped", partial = "Partial"
    }

    private var activeFilterCount: Int {
        var count = statusFilter != .all ? 1 : 0
        if updateFilter != .all { count += 1 }
        return count
    }

    private var pinnedIDs: Set<String> {
        pinnedStore.pinnedIDs(kind: .project, envID: environmentID)
    }

    /// Filters + sorts once and partitions in a single pass. Pure — reads the
    /// current inputs and returns the grouped sections without touching state.
    private func computeSections() -> [StableListSection<String, ProjectDetails>] {
        let query = debouncedSearchText
        let filtered = projects.filter { project in
            let matchesSearch = query.isEmpty ||
                project.displayName.localizedCaseInsensitiveContains(query)
            let status = project.status.lowercased()
            let matchesStatus = statusFilter == .all
                || (statusFilter == .running && status == "running")
                || (statusFilter == .stopped && (status == "stopped" || status == "exited"))
                || (statusFilter == .partial && (status == "partial" || status == "partially running"))
            let matchesUpdate = updateFilter.matches(hasUpdate: project.hasAvailableUpdate)
            return matchesSearch && matchesStatus && matchesUpdate
        }
        .sorted {
            sortOrder.areInIncreasingOrder($0.displayName, $1.displayName)
        }
        let pinned: Set<String> = pinnedIDs
        var pinnedItems: [ProjectDetails] = []
        var active: [ProjectDetails] = []
        var stopped: [ProjectDetails] = []
        for project in filtered {
            if pinned.contains(project.id) {
                pinnedItems.append(project)
            } else if isStopped(project) {
                stopped.append(project)
            } else {
                active.append(project)
            }
        }
        return [
            .init(id: "pinned", title: "Pinned", items: pinnedItems),
            .init(id: "active", title: "Active", items: active),
            .init(id: "stopped", title: "Stopped", items: stopped)
        ]
    }

    /// Refresh the cached `sections`. Called only when an input that affects
    /// grouping actually changes (search settle, sort, filter, pins, or the
    /// source list) — never on every body evaluation.
    private func rebuildSections(animated: Bool = false) {
        let new = computeSections()
        if animated {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) { sections = new }
        } else {
            sections = new
        }
    }

    private var isAdmin: Bool {
        manager.currentUser?.isAdmin == true
    }

    private var mutationVersion: Int {
        mutationStore.version(kind: .projects, envID: environmentID)
    }

    private var deleteAlertPresented: Binding<Bool> {
        Binding(
            get: { pendingDeleteProject != nil },
            set: { if !$0 { pendingDeleteProject = nil } }
        )
    }

    private var actionErrorPresented: Binding<Bool> {
        Binding(
            get: { actionErrorMessage != nil },
            set: { if !$0 { actionErrorMessage = nil } }
        )
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && projects.isEmpty {
            SkeletonListLoadingView()
        } else if let error = errorMessage, projects.isEmpty {
            ContentUnavailableView(
                "Error",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
        } else if projects.isEmpty {
            ContentUnavailableView {
                Label("No Projects", systemImage: "square.stack.3d.up")
            } description: {
                Text("No Compose projects found in this environment.")
            } actions: {
                Button("Create Project") { showCreateSheet = true }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            projectsList
        }
    }

    private var projectsList: some View {
        List {
            StableSectionedList(sections) { project in
                projectLink(project)
            }

            if hasMore {
                SkeletonListRow()
                    .skeletonShimmer()
                    .onAppear {
                        Task { await loadMore() }
                    }
            }
        }
        .listStyle(.insetGrouped)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if isAdmin {
            ToolbarItem(placement: .navigationBarLeading) {
                NavigationLink(destination: TemplateRegistriesView()) {
                    Image(systemName: "doc.text.magnifyingglass")
                }
                .accessibilityLabel("Template registries")
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            moreOptionsMenu
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Button { showCreateSheet = true } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Create project")
        }
    }

    private var moreOptionsMenu: some View {
        Menu {
            Picker("Sort", selection: $sortOrder) {
                ForEach(ListSortOrder.allCases) { order in
                    Label(order.title, systemImage: order.systemImage).tag(order)
                }
            }
            Button {
                showFilterSheet = true
            } label: {
                Label(
                    activeFilterCount > 0 ? "Filter (\(activeFilterCount))" : "Filter…",
                    systemImage: "line.3.horizontal.decrease.circle"
                )
            }
            Divider()
            NavigationLink(destination: ArchivedProjectsView(environmentID: environmentID)) {
                Label("Archived Projects", systemImage: "archivebox")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("More options")
    }

    private var filterSheetContent: some View {
        NavigationStack {
            Form {
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
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showFilterSheet = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    var body: some View {
        content
        .navigationTitle("Projects")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search projects")
        .toolbar {
            toolbarContent
        }
        .task { await loadProjects(reset: true) }
        .refreshable { await loadProjects(reset: true, refresh: true) }
        .debounce(searchText, for: .milliseconds(200), into: $debouncedSearchText)
        .navigationDestination(for: ProjectDetails.self) { project in
            ProjectDetailView(project: project, environmentID: environmentID)
                .navigationTransition(.zoom(sourceID: project.id, in: heroTransition))
        }
        .sheet(isPresented: $showCreateSheet) {
            CreateProjectView(environmentID: environmentID) {}
        }
        .sheet(isPresented: $showFilterSheet) { filterSheetContent }
        .onChange(of: mutationVersion) { _, _ in
            Task { await loadProjects(reset: true, refresh: true) }
        }
        .onChange(of: debouncedSearchText) { rebuildSections() }
        .onChange(of: statusFilter) { rebuildSections() }
        .onChange(of: updateFilter) { rebuildSections() }
        .onChange(of: sortOrder) { rebuildSections(animated: true) }
        .onChange(of: pinnedIDs) { rebuildSections() }
        .alert(
            "Delete Project",
            isPresented: deleteAlertPresented,
            presenting: pendingDeleteProject
        ) { project in
            Button("Delete", role: .destructive) {
                Task { await deleteProject(project, removeFiles: false) }
            }
            Button("Delete and Remove Files", role: .destructive) {
                Task { await deleteProject(project, removeFiles: true) }
            }
            Button("Cancel", role: .cancel) { pendingDeleteProject = nil }
        } message: { _ in
            Text("Remove the project from Arcane, or also remove its files from disk.")
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

    private func loadProjects(reset: Bool, refresh: Bool = false) async {
        guard let client = manager.client else { return }
        loadGeneration += 1
        let generation = loadGeneration
        let requestedPage = reset ? 1 : currentPage + 1
        let start = max(0, (requestedPage - 1) * Self.pageSize)
        if projects.isEmpty { isLoading = true }
        errorMessage = nil
        defer {
            if loadGeneration == generation {
                isLoading = false
            }
        }
        do {
            // `PaginatedResponse<ProjectDetails>` is Decodable-only, so we can't
            // route it through the cache layer (which requires Codable). The
            // service call is fast enough that this is fine.
            let query = SearchPaginationSort(start: start, limit: Self.pageSize)
            let response = try await client.projects.list(envID: environmentID, query: query)
            applyProjectsPage(response, reset: reset, generation: generation)
        } catch {
            guard loadGeneration == generation else { return }
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func applyProjectsPage(_ response: PaginatedResponse<ProjectDetails>, reset: Bool, generation: Int) {
        guard loadGeneration == generation else { return }
        if reset {
            projects = response.data
        } else {
            let existing = Set(projects.map(\.id))
            projects.append(contentsOf: response.data.filter { !existing.contains($0.id) })
        }
        currentPage = max(Int(response.pagination.currentPage), 1)
        hasMore = response.pagination.currentPage < response.pagination.totalPages
        rebuildSections()
    }

    private func loadMore() async {
        guard hasMore, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        await loadProjects(reset: false)
    }

    private func projectLink(_ project: ProjectDetails) -> some View {
        let isPinned = pinnedIDs.contains(project.id)
        return NavigationLink(value: project) {
            ProjectRow(project: project, isPinned: isPinned)
        }
        .matchedTransitionSource(id: project.id, in: heroTransition)
        .contextMenu {
            Button {
                togglePin(project)
            } label: {
                Label(isPinned ? "Unpin" : "Pin",
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
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                togglePinAfterSwipe(project)
            } label: {
                Label(isPinned ? "Unpin" : "Pin",
                      systemImage: isPinned ? "pin.slash.fill" : "pin.fill")
            }
            .tint(.yellow)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                pendingDeleteProject = project
            } label: {
                DestructiveLabel(text: "Delete")
            }
        }
    }

    private func togglePinAfterSwipe(_ project: ProjectDetails) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            togglePin(project)
        }
    }

    private func togglePin(_ project: ProjectDetails) {
        HapticsManager.light()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            pinnedStore.togglePin(project.id, kind: .project, envID: environmentID)
        }
    }

    private func projectPreview(_ project: ProjectDetails) -> some View {
        let status = project.status.lowercased()
        let color: Color
        switch status {
        case "running": color = .green
        case "stopped", "exited": color = .red
        case "partial", "partially running": color = .orange
        default: color = .secondary
        }
        var details: [RowPreviewCard.PreviewDetail] = [
            .init(icon: "circle.grid.2x2", label: "Services",
                  value: "\(project.runningCount)/\(project.serviceCount) running")
        ]
        if let version = project.composeVersion {
            details.append(.init(icon: "doc.text", label: "Compose Version", value: version))
        }
        details.append(.init(icon: "calendar", label: "Created", value: project.createdAt))
        return RowPreviewCard(
            icon: "square.stack.3d.up.fill",
            iconColor: color,
            title: project.displayName,
            badges: [
                .init(text: project.status.capitalized, color: color)
            ],
            details: details
        )
    }

    private func deleteProject(_ project: ProjectDetails, removeFiles: Bool) async {
        guard let client = manager.client else { return }
        pendingDeleteProject = nil
        do {
            let path = client.rest.environmentPath(environmentID, "projects/\(project.id)/destroy")
            let request = DestroyProjectRequest(removeFiles: removeFiles, removeVolumes: false)
            let _: DataResponse<String> = try await client.transport.request(path, method: "DELETE", body: request)
            withAnimation {
                projects.removeAll { $0.id == project.id }
                rebuildSections()
            }
            await invalidateProjectCaches()
            mutationStore.markChanged(kind: .projects, envID: environmentID)
        } catch {
            actionErrorMessage = friendlyErrorMessage(error)
        }
    }

    private func invalidateProjectCaches() async {
        guard let cached = manager.cached, let client = manager.client else { return }
        await cached.invalidate(envID: environmentID, paths: [
            client.rest.environmentPath(environmentID, "projects") + "*",
            client.rest.environmentPath(environmentID, "projects/*")
        ])
    }

    private func isStopped(_ project: ProjectDetails) -> Bool {
        let status = project.status.lowercased()
        return status == "stopped" || status == "exited"
    }
}

struct ProjectRow: View {
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

    var body: some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: project.iconUrl, size: 36) {
                if #available(iOS 26, *) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .glassEffect(.regular.tint(.orange), in: .circle)
                } else {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.orange, in: .circle)
                }
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(project.displayName)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                            .accessibilityHidden(true)
                    }
                }
            }

            Spacer()

            StatusIcon(status: project.status)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        let count = project.serviceCount
        var parts: [String] = [project.displayName]
        if isPinned { parts.append("pinned") }
        parts.append(project.status)
        parts.append("\(count) service\(count == 1 ? "" : "s")")
        return parts.joined(separator: ", ")
    }
}
