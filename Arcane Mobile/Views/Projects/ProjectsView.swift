import SwiftUI
import Arcane

struct ProjectsView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(PinnedItemsStore.self) private var pinnedStore
    let environmentID: EnvironmentID
    let environmentName: String

    @State private var projects: [Project] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var showCreateSheet = false
    @State private var showFilterSheet = false
    @State private var statusFilter = ProjectStatusFilter.all
    @State private var sortOrder = ListSortOrder.ascending

    private enum ProjectStatusFilter: String, CaseIterable {
        case all = "All", running = "Running", stopped = "Stopped", partial = "Partial"
    }

    private var activeFilterCount: Int { statusFilter != .all ? 1 : 0 }

    private var filtered: [Project] {
        projects.filter { project in
            let matchesSearch = searchText.isEmpty ||
                project.displayName.localizedCaseInsensitiveContains(searchText)
            let status = project.status.lowercased()
            let matchesStatus = statusFilter == .all
                || (statusFilter == .running && status == "running")
                || (statusFilter == .stopped && (status == "stopped" || status == "exited"))
                || (statusFilter == .partial && (status == "partial" || status == "partially running"))
            return matchesSearch && matchesStatus
        }
        .sorted {
            sortOrder.areInIncreasingOrder($0.displayName, $1.displayName)
        }
    }

    private var pinnedIDs: Set<String> {
        pinnedStore.pinnedIDs(kind: .project, envID: environmentID)
    }

    private var pinnedProjects: [Project] {
        filtered.filter { pinnedIDs.contains($0.id) }
    }

    private var activeProjects: [Project] {
        filtered.filter { !isStopped($0) && !pinnedIDs.contains($0.id) }
    }

    private var stoppedProjects: [Project] {
        filtered.filter { isStopped($0) && !pinnedIDs.contains($0.id) }
    }

    private var isAdmin: Bool {
        manager.currentUser?.isAdmin == true
    }

    var body: some View {
        Group {
            if isLoading && projects.isEmpty {
                ProgressView("Loading projects...").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage, projects.isEmpty {
                ContentUnavailableView("Error", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if projects.isEmpty {
                ContentUnavailableView("No Projects", systemImage: "square.stack.3d.up", description: Text("No Compose projects found"))
            } else {
                List {
                    if !pinnedProjects.isEmpty {
                        Section("Pinned") {
                            ForEach(pinnedProjects) { project in
                                projectLink(project)
                            }
                        }
                    }

                    if !activeProjects.isEmpty {
                        Section("Active") {
                            ForEach(activeProjects) { project in
                                projectLink(project)
                            }
                        }
                    }

                    if !stoppedProjects.isEmpty {
                        Section("Stopped") {
                            ForEach(stoppedProjects) { project in
                                projectLink(project)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Projects")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search projects")
        .toolbar {
            if isAdmin {
                ToolbarItem(placement: .navigationBarLeading) {
                    NavigationLink(destination: TemplateRegistriesView()) {
                        Image(systemName: "doc.text.magnifyingglass")
                    }
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Picker("Sort", selection: $sortOrder) {
                        ForEach(ListSortOrder.allCases) { order in
                            Label(order.title, systemImage: order.systemImage).tag(order)
                        }
                    }
                    Button {
                        showFilterSheet = true
                    } label: {
                        Label(activeFilterCount > 0 ? "Filter (\(activeFilterCount))" : "Filter…", systemImage: "line.3.horizontal.decrease.circle")
                    }
                    Divider()
                    NavigationLink(destination: ArchivedProjectsView(environmentID: environmentID)) {
                        Label("Archived Projects", systemImage: "archivebox")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showCreateSheet = true } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .task { await loadProjects() }
        .refreshable { await loadProjects(refresh: true) }
        .sheet(isPresented: $showCreateSheet) {
            CreateProjectView(environmentID: environmentID) { await loadProjects(refresh: true) }
        }
        .sheet(isPresented: $showFilterSheet) {
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
    }

    private func loadProjects(refresh: Bool = false) async {
        guard let client = manager.client, let cached = manager.cached else { return }
        if projects.isEmpty { isLoading = true }
        errorMessage = nil
        defer { isLoading = false }
        do {
            let path = client.rest.environmentPath(environmentID, "projects")
            if let result: [Project] = try await cached.getList(
                path, elementType: Project.self, policy: .projects,
                envID: environmentID, refresh: refresh,
                onFresh: { fresh in projects = fresh }
            ) {
                projects = result
            }
        } catch { errorMessage = friendlyErrorMessage(error) }
    }

    private func projectLink(_ project: Project) -> some View {
        let isPinned = pinnedIDs.contains(project.id)
        return NavigationLink(destination: ProjectDetailView(project: project, environmentID: environmentID)) {
            ProjectRow(project: project, isPinned: isPinned)
        }
        .contextMenu {
            Button {
                pinnedStore.togglePin(project.id, kind: .project, envID: environmentID)
            } label: {
                Label(isPinned ? "Unpin" : "Pin",
                      systemImage: isPinned ? "pin.slash.fill" : "pin.fill")
            }
            Button(role: .destructive) {
                Task { await deleteProject(project) }
            } label: {
                DestructiveLabel(text: "Delete")
            }
            .tint(.red)
        } preview: {
            projectPreview(project)
        }
        .swipeActions(edge: .leading) {
            Button {
                pinnedStore.togglePin(project.id, kind: .project, envID: environmentID)
            } label: {
                Label(isPinned ? "Unpin" : "Pin",
                      systemImage: isPinned ? "pin.slash.fill" : "pin.fill")
            }
            .tint(.yellow)
        }
        .swipeActions(edge: .trailing) {
            Button {
                Task { await deleteProject(project) }
            } label: {
                DestructiveLabel(text: "Delete")
            }
            .tint(.red)
        }
    }

    private func projectPreview(_ project: Project) -> some View {
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

    private func deleteProject(_ project: Project) async {
        guard let client = manager.client else { return }
        do {
            let path = client.rest.environmentPath(environmentID, "projects/\(project.id)/destroy")
            let _: DataResponse<String> = try await client.rest.delete(path)
            projects.removeAll { $0.id == project.id }
            if let cached = manager.cached {
                await cached.invalidate(envID: environmentID, paths: [
                    client.rest.environmentPath(environmentID, "projects"),
                    client.rest.environmentPath(environmentID, "projects/*")
                ])
            }
        } catch {}
    }

    private func isStopped(_ project: Project) -> Bool {
        let status = project.status.lowercased()
        return status == "stopped" || status == "exited"
    }
}

struct ProjectRow: View {
    let project: Project
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
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.title3)
                    .foregroundStyle(.indigo)
                    .frame(width: 36, height: 36)
                    .glassEffect(.regular, in: .circle)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(project.displayName)
                        .font(.headline)
                        .lineLimit(1)
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                }
                let count = project.serviceCount
                Text("\(count) service\(count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            StatusBadge(status: project.status)
        }
        .padding(.vertical, 2)
    }
}
