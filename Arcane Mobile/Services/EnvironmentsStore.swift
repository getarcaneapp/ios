import Arcane
import Foundation
import Observation

/// Shared environment list for Dashboard and Environments.
@MainActor
@Observable
final class EnvironmentsStore {
    private(set) var environments: [Arcane.Environment] = []
    private(set) var environmentCatalogRevision = 0
    private(set) var dockerInfoByEnvironmentID: [String: DockerInfo] = [:]
    private(set) var unavailableEnvironmentIDs: Set<String> = []
    private(set) var dockerInformationRevision = 0
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?

    let dashboardStream = DashboardStreamStore()
    let statsHistory = SystemStatsHistoryStore()

    private var loadGeneration = 0
    private var clientIdentity: ObjectIdentifier?
    private var dockerInformationTask: Task<Void, Never>?
    private var dockerInformationTaskID: UUID?
    private var actionItemsTask: Task<Void, Never>?
    private var actionItemsTaskID: UUID?
    /// Whether the per-environment docker info and snapshot passes have run
    /// for the current catalog. A list-only load (All Environments lists)
    /// fetches the catalog without them; the Dashboard's later load starts them.
    private var hasStartedEnvironmentDetails = false
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []
    private var visibleConsumers: Set<String> = []
    private var dashboardStreamConsumers: Set<String> = []

    func configure(client: ArcaneClient?) {
        let identity = client.map { ObjectIdentifier($0.transport) }
        guard identity != clientIdentity else { return }
        dockerInformationTask?.cancel()
        dockerInformationTask = nil
        dockerInformationTaskID = nil
        actionItemsTask?.cancel()
        actionItemsTask = nil
        actionItemsTaskID = nil
        hasStartedEnvironmentDetails = false
        loadGeneration &+= 1
        isLoading = false
        let waiters = loadWaiters
        loadWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        clientIdentity = identity
        dashboardStream.configure(client: client)
        statsHistory.configure(client: client)
        environments = []
        environmentCatalogRevision &+= 1
        dockerInfoByEnvironmentID = [:]
        unavailableEnvironmentIDs = []
        dockerInformationRevision &+= 1
        hasLoaded = false
        errorMessage = nil
        updateStreams()
    }

    func setVisible(_ visible: Bool, consumer: String, supportsDashboardStream: Bool) {
        if visible {
            visibleConsumers.insert(consumer)
            if supportsDashboardStream {
                dashboardStreamConsumers.insert(consumer)
            } else {
                dashboardStreamConsumers.remove(consumer)
            }
        } else {
            visibleConsumers.remove(consumer)
            dashboardStreamConsumers.remove(consumer)
        }

        updateStreams()
    }

    private func updateStreams() {
        if visibleConsumers.isEmpty || clientIdentity == nil {
            dashboardStream.stop()
            statsHistory.stop()
        } else {
            statsHistory.start()
            if dashboardStreamConsumers.isEmpty {
                dashboardStream.stop()
            } else {
                dashboardStream.start()
            }
        }
    }

    /// Loads the environment catalog. `refresh` refetches it even when loaded.
    /// `loadsEnvironmentDetails` also starts the per-environment docker info
    /// and dashboard snapshot passes the Dashboard and its cards show.
    func load(
        manager: ArcaneClientManager, refresh: Bool = false, loadsEnvironmentDetails: Bool = true
    ) async {
        configure(client: manager.client)
        guard let client = manager.client, let cached = manager.cached else { return }
        if hasLoaded && !refresh {
            if loadsEnvironmentDetails, !hasStartedEnvironmentDetails { startEnvironmentDetails(client: client) }
            return
        }
        if isLoading {
            await withCheckedContinuation { continuation in
                loadWaiters.append(continuation)
            }
            if loadsEnvironmentDetails, hasLoaded, !hasStartedEnvironmentDetails {
                startEnvironmentDetails(client: client)
            }
            return
        }
        let generation = loadGeneration
        let session = manager.cacheSessionIdentity
        let activeEnvironmentID = manager.activeEnvironmentID.rawValue

        isLoading = true
        if !hasLoaded { errorMessage = nil }
        defer {
            if generation == loadGeneration {
                isLoading = false
                let waiters = loadWaiters
                loadWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }

        do {
            let loaded = try await cached.getAllPagesGlobal(
                path: "environments",
                elementType: Arcane.Environment.self,
                fetchPage: { start, limit in
                    let response = try await client.environments.list(
                        query: .init(start: start, limit: limit, sortOrder: .ascending)
                    )
                    return ResourcePage(items: response.data, pagination: response.pagination)
                }
            )
            guard !Task.isCancelled, generation == loadGeneration, session == manager.cacheSessionIdentity else {
                return
            }
            let isFirstLoad = !hasLoaded
            hasLoaded = true
            apply(
                environments: loaded,
                activeEnvironmentID: activeEnvironmentID, server: manager.serverURL,
                forcesRevision: isFirstLoad
            )
            errorMessage = nil
            if loadsEnvironmentDetails {
                startEnvironmentDetails(client: client, refreshesSnapshots: refresh)
            }
        } catch is CancellationError {
            return
        } catch {
            guard generation == loadGeneration, session == manager.cacheSessionIdentity else { return }
            if !hasLoaded { errorMessage = friendlyErrorMessage(error) }
        }
    }

    func refreshDockerInformation(for environmentID: String, client: ArcaneClient?) async {
        guard let client else { return }
        let generation = loadGeneration
        let identity = ObjectIdentifier(client.transport)
        guard identity == clientIdentity else { return }
        let id = EnvironmentID(rawValue: environmentID)
        async let dockerInfo: DockerInfo? = try? await RemoteDataLimits.boundedDockerInfo(
            client: client,
            environmentID: id
        )
        async let snapshotRefresh: Void = dashboardStream.refresh(environmentIDs: [environmentID])
        let (loadedDockerInfo, _) = await (dockerInfo, snapshotRefresh)

        guard !Task.isCancelled, generation == loadGeneration, identity == clientIdentity else { return }
        if let loadedDockerInfo {
            dockerInfoByEnvironmentID[environmentID] = loadedDockerInfo
            unavailableEnvironmentIDs.remove(environmentID)
        } else {
            dockerInfoByEnvironmentID.removeValue(forKey: environmentID)
            unavailableEnvironmentIDs.insert(environmentID)
        }
        dockerInformationRevision &+= 1
    }

    /// Awaits the docker info pass. Joins one already in flight (a refresh
    /// that just started it) unless `restart` asks for a pass that begins now.
    func refreshDockerInformation(client: ArcaneClient?, restart: Bool = false) async {
        guard let client else { return }
        let task =
            (!restart ? dockerInformationTask : nil) ?? startDockerInformationLoad(client: client)
        await task.value
    }

    /// Awaits the dashboard snapshot (action items) pass, joining one in flight.
    func refreshActionItems(client: ArcaneClient?) async {
        guard let client else { return }
        let task = actionItemsTask ?? startActionItemsLoad(client: client, refreshesSnapshots: true)
        await task.value
    }

    /// Server-computed action items for one environment, from its current
    /// dashboard snapshot (live stream or REST refresh).
    func actionItems(for environmentID: String) -> ActionItems? {
        guard let state = dashboardStream.state(for: environmentID), state.hasLoaded else { return nil }
        return state.snapshot?.actionItems
    }

    func prioritizeStats(activeEnvironmentID: String) {
        statsHistory.reconcile(environments: statsOrdered(activeEnvironmentID: activeEnvironmentID))
    }

    private func apply(
        environments: [Arcane.Environment], activeEnvironmentID: String, server: String, forcesRevision: Bool
    ) {
        guard forcesRevision || environments != self.environments else { return }
        EnvironmentColorStore.shared.assignDefaults(server: server, environmentIDs: environments.map(\.id))
        self.environments = environments
        environmentCatalogRevision &+= 1
        dashboardStream.reconcile(environments: environments)
        prioritizeStats(activeEnvironmentID: activeEnvironmentID)
    }

    private func statsOrdered(activeEnvironmentID: String) -> [Arcane.Environment] {
        guard let activeIndex = environments.firstIndex(where: { $0.id == activeEnvironmentID }) else {
            return environments
        }
        var ordered = environments
        let active = ordered.remove(at: activeIndex)
        ordered.insert(active, at: 0)
        return ordered
    }

    private func startEnvironmentDetails(client: ArcaneClient, refreshesSnapshots: Bool = false) {
        hasStartedEnvironmentDetails = true
        startDockerInformationLoad(client: client)
        startActionItemsLoad(client: client, refreshesSnapshots: refreshesSnapshots)
    }

    @discardableResult
    private func startDockerInformationLoad(client: ArcaneClient) -> Task<Void, Never> {
        dockerInformationTask?.cancel()
        let identity = ObjectIdentifier(client.transport)
        let taskID = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.loadDockerInformation(client: client, identity: identity)
            if self.dockerInformationTaskID == taskID {
                self.dockerInformationTask = nil
                self.dockerInformationTaskID = nil
            }
        }
        dockerInformationTask = task
        dockerInformationTaskID = taskID
        return task
    }

    /// Dashboard snapshots carry each environment's action items. While the
    /// aggregated stream runs it delivers them for every environment on
    /// connect, so a REST pass is only needed without a stream or when a
    /// refresh must not wait for the server's reconcile tick.
    @discardableResult
    private func startActionItemsLoad(client: ArcaneClient, refreshesSnapshots: Bool) -> Task<Void, Never> {
        actionItemsTask?.cancel()
        let taskID = UUID()
        let stream = dashboardStream
        let task = Task { [weak self] in
            guard let self else { return }
            if refreshesSnapshots || !stream.isStreaming || stream.streamUnsupported {
                await stream.refresh()
            }
            if self.actionItemsTaskID == taskID {
                self.actionItemsTask = nil
                self.actionItemsTaskID = nil
            }
        }
        actionItemsTask = task
        actionItemsTaskID = taskID
        return task
    }

    private func loadDockerInformation(client: ArcaneClient, identity: ObjectIdentifier) async {
        let enabledIDs = environments.filter(\.enabled).map(\.id)
        let enabledSet = Set(enabledIDs)
        let pruned = dockerInfoByEnvironmentID.filter { enabledSet.contains($0.key) }
        if pruned.count != dockerInfoByEnvironmentID.count { dockerInfoByEnvironmentID = pruned }
        let available = unavailableEnvironmentIDs.intersection(enabledSet)
        if available != unavailableEnvironmentIDs { unavailableEnvironmentIDs = available }

        // Every environment loads at once; results publish as they arrive,
        // coalesced so the dashboard re-renders a few times, not once per env.
        await ProgressiveFanOut.run(enabledIDs) { environmentID in
            let info = try? await RemoteDataLimits.boundedDockerInfo(
                client: client,
                environmentID: EnvironmentID(rawValue: environmentID)
            )
            return (environmentID, info)
        } deliver: { batch in
            guard !Task.isCancelled, identity == clientIdentity else { return }
            for (environmentID, info) in batch {
                if let info {
                    dockerInfoByEnvironmentID[environmentID] = info
                    unavailableEnvironmentIDs.remove(environmentID)
                } else {
                    dockerInfoByEnvironmentID.removeValue(forKey: environmentID)
                    unavailableEnvironmentIDs.insert(environmentID)
                }
            }
            dockerInformationRevision &+= 1
        }
    }
}
