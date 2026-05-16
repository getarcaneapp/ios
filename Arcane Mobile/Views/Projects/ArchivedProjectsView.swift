import SwiftUI
import Arcane

struct ArchivedProjectsView: View {
    private static let pageSize = 50

    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutationStore
    let environmentID: EnvironmentID

    @State private var projects: [ProjectDetails] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var unarchivingID: String?
    @State private var currentPage = 1
    @State private var hasMore = false
    @State private var loadGeneration = 0

    private var sortedProjects: [ProjectDetails] {
        projects.sorted { lhs, rhs in
            (lhs.archivedAt ?? .distantPast) > (rhs.archivedAt ?? .distantPast)
        }
    }

    private var mutationVersion: Int {
        mutationStore.version(kind: .projects, envID: environmentID)
    }

    var body: some View {
        Group {
            if isLoading && projects.isEmpty {
                ProgressView("Loading archived projects...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage, projects.isEmpty {
                ContentUnavailableView(
                    "Error",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else if projects.isEmpty {
                ContentUnavailableView(
                    "No Archived Projects",
                    systemImage: "archivebox",
                    description: Text("Archived projects will appear here.")
                )
            } else {
                List {
                    ForEach(sortedProjects) { project in
                        ArchivedProjectRow(project: project)
                            .contextMenu {
                                Button {
                                    Task { await unarchive(project) }
                                } label: {
                                    Label("Unarchive", systemImage: "tray.and.arrow.up")
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                Button {
                                    Task { await unarchive(project) }
                                } label: {
                                    Label("Unarchive", systemImage: "tray.and.arrow.up")
                                }
                                .tint(.indigo)
                            }
                    }

                    if hasMore {
                        Button("Load More") {
                            Task { await loadMore() }
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Archived Projects")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load(reset: true) }
        .refreshable { await load(reset: true, refresh: true) }
        .onChange(of: mutationVersion) { _, _ in
            Task { await load(reset: true, refresh: true) }
        }
    }

    private func load(reset: Bool, refresh: Bool = false) async {
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
            // route it through the cache layer (which requires Codable).
            let query = SearchPaginationSort(start: start, limit: Self.pageSize)
            let response = try await client.projects.list(
                envID: environmentID,
                query: query,
                archived: "true"
            )
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
    }

    private func loadMore() async {
        guard hasMore else { return }
        await load(reset: false)
    }

    private func unarchive(_ project: ProjectDetails) async {
        guard let client = manager.client else { return }
        unarchivingID = project.id
        defer { unarchivingID = nil }
        do {
            let path = client.rest.environmentPath(environmentID, "projects/\(project.id)/unarchive")
            let _: DataResponse<String> = try await client.rest.post(path, body: String?.none)
            projects.removeAll { $0.id == project.id }
            await invalidateProjectCaches()
            mutationStore.markChanged(kind: .projects, envID: environmentID)
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func invalidateProjectCaches() async {
        guard let cached = manager.cached, let client = manager.client else { return }
        await cached.invalidate(envID: environmentID, paths: [
            client.rest.environmentPath(environmentID, "projects") + "*",
            client.rest.environmentPath(environmentID, "projects/*")
        ])
    }
}

private struct ArchivedProjectRow: View {
    let project: ProjectDetails

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: project.iconUrl, size: 36) {
                Image(systemName: "archivebox.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .glassEffect(.regular, in: .circle)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(project.displayName)
                    .font(.headline)
                    .lineLimit(1)
                if let archivedAt = project.archivedAt {
                    Text("Archived \(Self.dateFormatter.string(from: archivedAt))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Archived")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(.vertical, 2)
    }
}
