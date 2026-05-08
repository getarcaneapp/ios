import SwiftUI
import Arcane

struct ProjectsView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
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

    private var activeProjects: [Project] {
        filtered.filter { !isStopped($0) }
    }

    private var stoppedProjects: [Project] {
        filtered.filter(isStopped)
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
                    ResourceSearchControls(
                        searchText: $searchText,
                        sortOrder: $sortOrder,
                        prompt: "Search projects",
                        filterActive: activeFilterCount > 0
                    ) {
                        showFilterSheet = true
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)

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
        .toolbar {
            if isAdmin {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink(destination: TemplateRegistriesView()) {
                        Image(systemName: "doc.text.magnifyingglass")
                    }
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { Task { await loadProjects() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showCreateSheet = true } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .task { await loadProjects() }
        .refreshable { await loadProjects() }
        .sheet(isPresented: $showCreateSheet) {
            CreateProjectView(environmentID: environmentID) { await loadProjects() }
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

    private func loadProjects() async {
        guard let client = manager.client else { return }
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            let path = client.rest.environmentPath(environmentID, "projects")
            projects = try await client.rest.get(path)
        } catch { errorMessage = error.localizedDescription }
    }

    private func projectLink(_ project: Project) -> some View {
        NavigationLink(destination: ProjectDetailView(project: project, environmentID: environmentID)) {
            ProjectRow(project: project)
        }
    }

    private func isStopped(_ project: Project) -> Bool {
        let status = project.status.lowercased()
        return status == "stopped" || status == "exited"
    }
}

struct ProjectRow: View {
    let project: Project

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
                Text(project.displayName)
                    .font(.headline)
                    .lineLimit(1)
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
