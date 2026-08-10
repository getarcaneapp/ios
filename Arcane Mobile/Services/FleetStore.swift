import Foundation
import Observation
import Arcane

/// Shared fleet ownership for Dashboard and Environments.
@MainActor
@Observable
final class FleetStore {
    private static let maxConcurrentEnvironmentRequests = 4
    private(set) var environments: [Arcane.Environment] = []
    private(set) var environmentCatalogRevision = 0
    private(set) var dockerInfoByEnvironmentID: [String: DockerInfo] = [:]
    private(set) var actionItemsByEnvironmentID: [String: ActionItems] = [:]
    private(set) var unavailableEnvironmentIDs: Set<String> = []
    private(set) var dockerInformationRevision = 0
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?

    let dashboardStream = DashboardStreamStore()
    let statsHistory = SystemStatsHistoryStore()

    private var clientIdentity: ObjectIdentifier?
    private var dockerInformationTask: Task<Void, Never>?
    private var actionItemsTask: Task<Void, Never>?
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []
    private var visibleConsumers: Set<String> = []
    private var dashboardStreamConsumers: Set<String> = []

    func configure(client: ArcaneClient?) {
        let identity = client.map { ObjectIdentifier($0.transport) }
        guard identity != clientIdentity else { return }
        dockerInformationTask?.cancel()
        dockerInformationTask = nil
        actionItemsTask?.cancel()
        actionItemsTask = nil
        clientIdentity = identity
        dashboardStream.configure(client: client)
        statsHistory.configure(client: client)
        environments = []
        environmentCatalogRevision &+= 1
        dockerInfoByEnvironmentID = [:]
        actionItemsByEnvironmentID = [:]
        unavailableEnvironmentIDs = []
        dockerInformationRevision &+= 1
        hasLoaded = false
        errorMessage = nil
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

        if visibleConsumers.isEmpty {
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

    func load(manager: ArcaneClientManager, refresh: Bool = false) async {
        configure(client: manager.client)
        guard let client = manager.client, let cached = manager.cached else { return }
        if hasLoaded && !refresh { return }
        if isLoading {
            await withCheckedContinuation { continuation in
                loadWaiters.append(continuation)
            }
            return
        }
        let activeEnvironmentID = manager.activeEnvironmentID.rawValue

        isLoading = true
        if !hasLoaded { errorMessage = nil }
        defer {
            isLoading = false
            let waiters = loadWaiters
            loadWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }

        do {
            let loaded = try await cached.getAllPagesGlobal(
                path: "environments",
                elementType: Arcane.Environment.self,
                policy: .environments,
                refresh: refresh,
                onFresh: { [weak self] fresh in
                    self?.apply(
                        environments: fresh,
                        activeEnvironmentID: activeEnvironmentID
                    )
                },
                fetchPage: { start, limit in
                    let response = try await client.environments.list(
                        query: .init(start: start, limit: limit, sortOrder: .ascending)
                    )
                    return ResourcePage(items: response.data, pagination: response.pagination)
                }
            )
            if let loaded {
                apply(
                    environments: loaded,
                    activeEnvironmentID: activeEnvironmentID
                )
            }
            hasLoaded = true
            environmentCatalogRevision &+= 1
            errorMessage = nil
            startDockerInformationLoad(client: client)
            startActionItemsLoad(client: client)
        } catch is CancellationError {
            return
        } catch {
            if !hasLoaded { errorMessage = friendlyErrorMessage(error) }
        }
    }

    func refreshDockerInformation(for environmentID: String, client: ArcaneClient?) async {
        guard let client else { return }
        let id = EnvironmentID(rawValue: environmentID)
        async let dockerInfo: DockerInfo? = try? await RemoteDataLimits.boundedDockerInfo(
            client: client,
            environmentID: id
        )
        async let actionItems: ActionItems? = try? await client.dashboard.snapshot(envID: id).actionItems
        let (loadedDockerInfo, loadedActionItems) = await (dockerInfo, actionItems)

        if let loadedDockerInfo {
            dockerInfoByEnvironmentID[environmentID] = loadedDockerInfo
            unavailableEnvironmentIDs.remove(environmentID)
        } else {
            dockerInfoByEnvironmentID.removeValue(forKey: environmentID)
            unavailableEnvironmentIDs.insert(environmentID)
        }
        if let loadedActionItems {
            actionItemsByEnvironmentID[environmentID] = loadedActionItems
        } else {
            actionItemsByEnvironmentID.removeValue(forKey: environmentID)
        }
        dockerInformationRevision &+= 1
    }

    func refreshDockerInformation(client: ArcaneClient?) async {
        guard let client else { return }
        let task = startDockerInformationLoad(client: client)
        await task.value
    }

    func prioritizeStats(activeEnvironmentID: String) {
        statsHistory.reconcile(environments: statsOrdered(activeEnvironmentID: activeEnvironmentID))
    }

    private func apply(environments: [Arcane.Environment], activeEnvironmentID: String) {
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

    @discardableResult
    private func startDockerInformationLoad(client: ArcaneClient) -> Task<Void, Never> {
        dockerInformationTask?.cancel()
        let identity = ObjectIdentifier(client.transport)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.loadDockerInformation(client: client, identity: identity)
        }
        dockerInformationTask = task
        return task
    }

    @discardableResult
    private func startActionItemsLoad(client: ArcaneClient) -> Task<Void, Never> {
        actionItemsTask?.cancel()
        let identity = ObjectIdentifier(client.transport)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.loadActionItems(client: client, identity: identity)
        }
        actionItemsTask = task
        return task
    }

    private func loadActionItems(client: ArcaneClient, identity: ObjectIdentifier) async {
        let enabled = environments.filter(\.enabled)
        let enabledIDs = Set(enabled.map(\.id))
        actionItemsByEnvironmentID = actionItemsByEnvironmentID.filter { enabledIDs.contains($0.key) }

        await withTaskGroup(of: (String, ActionItems?).self) { group in
            var iterator = enabled.makeIterator()
            for _ in 0..<min(Self.maxConcurrentEnvironmentRequests, enabled.count) {
                guard let environment = iterator.next() else { break }
                group.addTask {
                    let items = try? await client.dashboard.snapshot(
                        envID: EnvironmentID(rawValue: environment.id)
                    ).actionItems
                    return (environment.id, items)
                }
            }

            for await (environmentID, items) in group {
                guard !Task.isCancelled, identity == clientIdentity else {
                    group.cancelAll()
                    return
                }
                if let items {
                    actionItemsByEnvironmentID[environmentID] = items
                } else {
                    actionItemsByEnvironmentID.removeValue(forKey: environmentID)
                }

                if let environment = iterator.next() {
                    group.addTask {
                        let items = try? await client.dashboard.snapshot(
                            envID: EnvironmentID(rawValue: environment.id)
                        ).actionItems
                        return (environment.id, items)
                    }
                }
            }
        }
    }

    private func loadDockerInformation(client: ArcaneClient, identity: ObjectIdentifier) async {
        let enabled = environments.filter(\.enabled)
        let enabledIDs = Set(enabled.map(\.id))
        dockerInfoByEnvironmentID = dockerInfoByEnvironmentID.filter { enabledIDs.contains($0.key) }
        unavailableEnvironmentIDs.formIntersection(enabledIDs)

        await withTaskGroup(of: (String, DockerInfo?).self) { group in
            var iterator = enabled.makeIterator()
            for _ in 0..<min(Self.maxConcurrentEnvironmentRequests, enabled.count) {
                guard let environment = iterator.next() else { break }
                group.addTask {
                    let info = try? await RemoteDataLimits.boundedDockerInfo(
                        client: client,
                        environmentID: EnvironmentID(rawValue: environment.id)
                    )
                    return (environment.id, info)
                }
            }

            for await (environmentID, info) in group {
                guard !Task.isCancelled, identity == clientIdentity else {
                    group.cancelAll()
                    return
                }
                if let info {
                    dockerInfoByEnvironmentID[environmentID] = info
                    unavailableEnvironmentIDs.remove(environmentID)
                } else {
                    dockerInfoByEnvironmentID.removeValue(forKey: environmentID)
                    unavailableEnvironmentIDs.insert(environmentID)
                }
                dockerInformationRevision &+= 1

                if let environment = iterator.next() {
                    group.addTask {
                        let info = try? await RemoteDataLimits.boundedDockerInfo(
                            client: client,
                            environmentID: EnvironmentID(rawValue: environment.id)
                        )
                        return (environment.id, info)
                    }
                }
            }
        }
    }
}
