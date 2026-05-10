import SwiftUI
import Arcane

struct ArchivedProjectsView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutationStore
    let environmentID: EnvironmentID

    @State private var projects: [Project] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var unarchivingID: String?

    private var sortedProjects: [Project] {
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
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Archived Projects")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load(refresh: true) }
        .onChange(of: mutationVersion) { _, _ in
            Task { await load(refresh: true) }
        }
    }

    private func load(refresh: Bool = false) async {
        guard let client = manager.client, let cached = manager.cached else { return }
        if projects.isEmpty { isLoading = true }
        errorMessage = nil
        defer { isLoading = false }
        do {
            let basePath = client.rest.environmentPath(environmentID, "projects")
            let cachePath = "\(basePath)?archived=true"
            let query = [URLQueryItem(name: "archived", value: "true")]
            let captured = client
            let fetcher: @Sendable () async throws -> [Project] = {
                try await captured.rest.get(basePath, query: query)
            }
            if let result: [Project] = try await cached.getListCustom(
                path: cachePath, elementType: Project.self, policy: .projects,
                envID: environmentID, refresh: refresh,
                onFresh: { fresh in projects = fresh },
                fetcher: fetcher
            ) {
                projects = result
            }
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func unarchive(_ project: Project) async {
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
    let project: Project

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
