import Arcane
import SwiftUI

struct AllEnvironmentsResourcesView: View {
    let kind: FleetResourceKind
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(FleetStore.self) private var fleet
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutations
    @State private var store = FleetResourcesStore()
    @State private var search = ""
    @State private var filters = FleetResourceFilters()
    @State private var sortOrder = ListSortOrder.ascending
    @State private var showFilters = false
    @State private var pendingMaintenanceAction: FleetMaintenanceAction?
    @State private var showPrune = false
    @State private var router = QuickActionRouter.shared
    @State private var routeEnvironment: FleetResourceBucket?

    private var requestID: String { "\(manager.clientGeneration)-\(kind.rawValue)-\(manager.allEnvironmentsPreview)" }

    private var visibleResources: [FleetResourceListItem] {
        store.buckets.flatMap { bucket in
            bucket.resources.map { FleetResourceListItem(resource: $0, bucket: bucket) }
        }
        .filter { filters.matches($0) }
        .filter {
            search.isEmpty || $0.bucket.name.localizedCaseInsensitiveContains(search)
                || $0.resource.searchText.localizedCaseInsensitiveContains(search)
        }
        .sorted {
            let order = $0.resource.searchText.localizedStandardCompare($1.resource.searchText)
            if order != .orderedSame {
                return sortOrder.areInIncreasingOrder($0.resource.searchText, $1.resource.searchText)
            }
            return $0.bucket.name.localizedStandardCompare($1.bucket.name) == .orderedAscending
        }
    }

    var body: some View {
        List {
            if let error = fleet.errorMessage {
                Label("Couldn't load environments", systemImage: "exclamationmark.triangle")
                Text(error).foregroundStyle(.secondary)
                Button("Retry") { Task { await load(refresh: true) } }
            }
            ForEach(store.buckets.filter { $0.error != nil }) { bucket in
                VStack(alignment: .leading, spacing: 6) {
                    Label("Couldn't load \(bucket.name)", systemImage: "exclamationmark.triangle")
                    Text(bucket.error ?? "").font(.footnote).foregroundStyle(.secondary)
                    Button("Retry") { Task { await load() } }
                }
            }
            ForEach(visibleResources) { item in
                NavigationLink {
                    FleetResourceDestination(resource: item.resource, bucket: item.bucket)
                        .safeAreaInset(edge: .top) {
                            Text(item.bucket.name).font(.subheadline).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity).padding(.vertical, 6)
                                .background(.bar)
                        }
                } label: {
                    resourceRow(
                        item.resource, environmentName: item.bucket.name, imageUpdates: item.bucket.imageUpdates
                    )
                    .environment(\.fleetEnvironmentID, item.bucket.id)
                }
            }
            if store.isLoading && !visibleResources.isEmpty { ProgressView("Loading…") }
        }
        .navigationTitle(kind.title)
        .searchable(text: $search, prompt: "Search resources or environments")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Sort", selection: $sortOrder) {
                        ForEach(ListSortOrder.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
                    }
                    Button {
                        showFilters = true
                    } label: {
                        Label(
                            filters.activeCount > 0 ? "Filter (\(filters.activeCount))" : "Filter…",
                            systemImage: "line.3.horizontal.decrease.circle")
                    }
                    if [.containers, .projects, .images].contains(kind) {
                        Divider()
                        Button("Update All", systemImage: "arrow.triangle.2.circlepath") {
                            pendingMaintenanceAction = .update
                        }
                        Button("Check All", systemImage: "arrow.clockwise") {
                            pendingMaintenanceAction = .checkImages
                        }
                    }
                    if [.containers, .images, .volumes, .networks].contains(kind) {
                        Divider()
                        Button(role: .destructive) {
                            showPrune = true
                        } label: {
                            DestructiveLabel(text: "Prune")
                        }
                        .tint(.red)
                    }
                } label: {
                    Label("More options", systemImage: "ellipsis.circle")
                }
                .disabled(store.buckets.isEmpty)
            }
        }
        .overlay {
            if (fleet.isLoading || store.isLoading) && visibleResources.isEmpty {
                ProgressView("Loading…")
            } else if fleet.hasLoaded && !store.isLoading && visibleResources.isEmpty && fleet.errorMessage == nil
                && store.buckets.allSatisfy({ $0.error == nil })
            {
                if !search.isEmpty {
                    ContentUnavailableView.search(text: search)
                } else {
                    ContentUnavailableView("No \(kind.title)", systemImage: "server.rack")
                }
            }
        }
        .task(id: requestID) { await load() }
        .refreshable { await load(refresh: true) }
        .onChange(of: router.pendingRoute, initial: true) { _, route in
            let environment: String?
            switch route {
            case .container(let id, _) where kind == .containers: environment = id
            case .project(let id, _) where kind == .projects: environment = id
            default: environment = nil
            }
            if let environment {
                routeEnvironment =
                    store.buckets.first { $0.id == environment }
                    ?? FleetResourceBucket(id: environment, name: environment)
            }
        }
        .fleetMaintenanceConfirmation(action: $pendingMaintenanceAction, environments: fleet.environments)
        .sheet(isPresented: $showPrune) {
            SystemPruneView(
                environmentID: manager.activeEnvironmentID, environments: fleet.environments.filter(\.enabled))
        }
        .sheet(isPresented: $showFilters) {
            FleetResourceFilterSheet(kind: kind, buckets: store.buckets, filters: $filters)
        }
        .sheet(item: $routeEnvironment) { bucket in
            NavigationStack {
                scopedTools(bucket)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Done") { routeEnvironment = nil } }
                    }
            }
        }
        .onChange(of: mutations.versions) { _, _ in Task { await load() } }
    }

    private func load(refresh: Bool = false) async {
        let session = manager.clientGeneration
        await fleet.load(manager: manager, refresh: refresh)
        guard !Task.isCancelled, session == manager.clientGeneration, manager.allEnvironmentsPreview else { return }
        guard let client = manager.client else { return }
        await store.load(kind: kind, environments: fleet.environments, client: client) {
            session == manager.clientGeneration && manager.allEnvironmentsPreview
        }
    }

    @ViewBuilder private func resourceRow(
        _ resource: FleetResource, environmentName: String, imageUpdates: [String: ImageUpdateResponse]
    ) -> some View {
        switch resource {
        case .container(let item): ContainerRow(container: item, environmentName: environmentName)
        case .project(let item): ProjectRow(project: item, environmentName: environmentName)
        case .network(let item): NetworkRow(network: item, environmentName: environmentName)
        case .volume(let item): VolumeRow(volume: item, environmentName: environmentName)
        case .image(let item):
            ImageRow(
                row: .init(
                    image: item, displayName: item.repoTags.first ?? item.id, sizeText: item.size.byteString,
                    updateState: ImageUpdateState.resolve(
                        inline: item.updateInfo, references: item.repoTags, results: imageUpdates)),
                environmentName: environmentName)
        case .port(let item): PortMappingRow(port: item, environmentName: environmentName)
        case .job(let item):
            Label {
                VStack(alignment: .leading) {
                    Text(item.name)
                    FleetEnvironmentLabel(name: environmentName)
                }
            } icon: {
                Image(systemName: "play.square.stack")
            }
        case .gitOps(let item):
            DynamicResourceRow(item: item, systemImage: "arrow.triangle.branch", environmentName: environmentName)
        case .vulnerability(let item):
            VStack(alignment: .leading) {
                Text(item.vulnerabilityId)
                Text(item.imageName + " · " + item.pkgName).font(.caption).foregroundStyle(.secondary)
                FleetEnvironmentLabel(name: environmentName)
            }
        case .topology:
            Label {
                VStack(alignment: .leading) {
                    Text("View network topology")
                    FleetEnvironmentLabel(name: environmentName)
                }
            } icon: {
                Image(systemName: "point.3.connected.trianglepath.dotted")
            }
        }
    }

    @ViewBuilder private func scopedTools(_ bucket: FleetResourceBucket) -> some View {
        Group {
            switch kind {
            case .containers: ContainersView(environmentID: bucket.environmentID, environmentName: bucket.name)
            case .projects: ProjectsView(environmentID: bucket.environmentID, environmentName: bucket.name)
            case .images: ImagesView(environmentID: bucket.environmentID, environmentName: bucket.name)
            case .networks: NetworksView(environmentID: bucket.environmentID, environmentName: bucket.name)
            case .volumes: VolumesView(environmentID: bucket.environmentID, environmentName: bucket.name)
            case .ports: PortsView(environmentID: bucket.environmentID)
            case .jobs: JobsView(environmentID: bucket.environmentID)
            case .gitOps: GitOpsSyncsView(environmentID: bucket.environmentID)
            case .vulnerabilities: AllVulnerabilitiesView(environmentID: bucket.environmentID)
            case .topology: NetworkTopologyView(environmentID: bucket.environmentID)
            }
        }
        .safeAreaInset(edge: .top) {
            Text(bucket.name).font(.subheadline).frame(maxWidth: .infinity).padding(6).background(.bar)
        }
    }
}

private struct FleetResourceDestination: View {
    let resource: FleetResource
    let bucket: FleetResourceBucket
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @State private var isRunning = false

    var body: some View {
        switch resource {
        case .container(let item): ContainerDetailView(container: item, environmentID: bucket.environmentID)
        case .project(let item): ProjectDetailView(project: item, environmentID: bucket.environmentID)
        case .image(let item): ImageDetailView(image: item, environmentID: bucket.environmentID)
        case .network(let item): NetworkDetailView(network: item, environmentID: bucket.environmentID)
        case .volume(let item): VolumeDetailView(volume: item, environmentID: bucket.environmentID)
        case .port(let item): PortMappingDetailView(port: item)
        case .job(let item):
            JobDetailView(environmentID: bucket.environmentID, job: item, isRunning: isRunning) { await run(item) }
        case .gitOps(let item): DynamicResourceDetailView(title: item.title, resource: item, actions: [])
        case .vulnerability(let item): VulnerabilityWithImageDetailView(record: item)
        case .topology: NetworkTopologyView(environmentID: bucket.environmentID)
        }
    }

    private func run(_ job: JobStatus) async {
        guard !isRunning, let client = manager.client else { return }
        isRunning = true
        defer { isRunning = false }
        do {
            let response = try await client.jobs.run(jobID: job.id, envID: bucket.environmentID)
            showToast(.success(response.message.isEmpty ? "Job started" : response.message))
        } catch { showToast(.error(friendlyErrorMessage(error))) }
    }
}
