import AppIntents
import WidgetKit
import Arcane

/// The only widget-button intent: refetches authoritative Docker counts plus
/// dashboard action metadata, rewrites the App-Group snapshot, and reloads
/// timelines. Mutation intents deliberately do NOT appear on widgets
/// (Shortcuts/Siri only).
struct RefreshDashboardIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh Arcane Status"
    static let description = IntentDescription("Fetches fresh container counts from your Arcane server.")

    private static let maxEnvironments = 10
    private static let maxConcurrentFetches = 4

    func perform() async throws -> some IntentResult {
        let client = try IntentClientFactory.makeClient()
        var environments: [Arcane.Environment] = []
        var inspectedEnvironmentCount = 0
        for try await environment in ArcanePaginator<Arcane.Environment>(
            limit: Self.maxEnvironments,
            fetch: { start, limit in
                try await client.environments.list(
                    query: SearchPaginationSort(start: start, limit: limit)
                )
            }
        ) {
            inspectedEnvironmentCount += 1
            if environment.enabled {
                environments.append(environment)
            }
            if inspectedEnvironmentCount == Self.maxEnvironments {
                break
            }
        }

        let previous = WidgetSnapshotStore.load()
        let previousByID = Dictionary(
            uniqueKeysWithValues: (previous?.environments ?? []).map { ($0.id, $0) }
        )
        let summaries = await loadSummaries(
            environments: environments,
            client: client,
            previousByID: previousByID
        )
        WidgetSnapshotStore.saveAndReloadIfChanged(WidgetSnapshot(
            generatedAt: Date(),
            serverConfigured: true,
            isDemo: previous?.isDemo ?? false,
            accentHex: AppGroup.defaults?.string(forKey: AppGroup.Keys.accentColorHex),
            activeEnvironmentID: IntentClientFactory.activeEnvironmentID.rawValue,
            environments: summaries,
            suggestedContainers: previous?.suggestedContainers ?? []
        ))
        return .result()
    }

    private func loadSummaries(
        environments: [Arcane.Environment],
        client: ArcaneClient,
        previousByID: [String: WidgetSnapshot.EnvSummary]
    ) async -> [WidgetSnapshot.EnvSummary] {
        await withTaskGroup(
            of: (Int, WidgetSnapshot.EnvSummary).self,
            returning: [WidgetSnapshot.EnvSummary].self
        ) { group in
            var iterator = environments.enumerated().makeIterator()
            for _ in 0..<min(Self.maxConcurrentFetches, environments.count) {
                guard let item = iterator.next() else { break }
                group.addTask {
                    (
                        item.offset,
                        await Self.loadSummary(
                            environment: item.element,
                            client: client,
                            previous: previousByID[item.element.id]
                        )
                    )
                }
            }

            var loaded: [(Int, WidgetSnapshot.EnvSummary)] = []
            for await summary in group {
                loaded.append(summary)
                if let item = iterator.next() {
                    group.addTask {
                        (
                            item.offset,
                            await Self.loadSummary(
                                environment: item.element,
                                client: client,
                                previous: previousByID[item.element.id]
                            )
                        )
                    }
                }
            }
            return loaded.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private static func loadSummary(
        environment: Arcane.Environment,
        client: ArcaneClient,
        previous: WidgetSnapshot.EnvSummary?
    ) async -> WidgetSnapshot.EnvSummary {
        let trimmedName = environment.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let displayName = trimmedName.isEmpty ? environment.id : trimmedName
        let environmentID = EnvironmentID(rawValue: environment.id)

        guard let dockerInfo = try? await client.system.dockerInfo(envID: environmentID) else {
            return .init(
                id: environment.id,
                name: displayName,
                online: false,
                running: 0,
                stopped: 0,
                total: 0,
                images: 0,
                updatesAvailable: previous?.updatesAvailable ?? 0,
                actionableVulnerabilities: previous?.actionableVulnerabilities
            )
        }

        let dashboard = try? await client.dashboard.snapshot(envID: environmentID)
        let updates = dashboard?.actionItems.items.first(where: {
            if case .imageUpdates = $0.kind { return true }
            return false
        })?.count ?? previous?.updatesAvailable ?? 0
        let vulnerabilities = dashboard?.actionItems.items.first(where: {
            if case .actionableVulnerabilities = $0.kind { return true }
            return false
        })?.count ?? previous?.actionableVulnerabilities

        return .init(
            id: environment.id,
            name: displayName,
            online: true,
            running: dockerCount("ContainersRunning", in: dockerInfo),
            stopped: dockerCount("ContainersStopped", in: dockerInfo),
            total: dockerCount("Containers", in: dockerInfo),
            images: dockerCount("Images", in: dockerInfo),
            updatesAvailable: updates,
            actionableVulnerabilities: vulnerabilities
        )
    }

    private static func dockerCount(_ key: String, in info: DockerInfo) -> Int {
        Int(info.info?[key]?.int64Value ?? 0)
    }
}
