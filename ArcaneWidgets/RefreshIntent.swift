import AppIntents
import WidgetKit
import Arcane

/// The only widget-button intent: refetches dashboard snapshots over the
/// network, rewrites the App-Group snapshot, and reloads timelines. Mutation
/// intents deliberately do NOT appear on widgets (Shortcuts/Siri only).
struct RefreshDashboardIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh Arcane Status"
    static let description = IntentDescription("Fetches fresh container counts from your Arcane server.")

    /// Widget-extension runtime is tightly budgeted; don't sweep huge fleets.
    private static let maxEnvironments = 10

    func perform() async throws -> some IntentResult {
        let client = try IntentClientFactory.makeClient()
        let response = try await client.environments.list(
            query: SearchPaginationSort(start: 0, limit: Self.maxEnvironments)
        )
        let environments = response.data.filter(\.enabled)

        var summaries: [WidgetSnapshot.EnvSummary] = []
        for environment in environments {
            let name = environment.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let displayName = name.isEmpty ? environment.id : name
            do {
                let snapshot = try await client.dashboard.snapshot(
                    envID: EnvironmentID(rawValue: environment.id)
                )
                let updates = snapshot.actionItems.items.first(where: {
                    if case .imageUpdates = $0.kind { return true }
                    return false
                })?.count ?? 0
                let vulnerabilities = snapshot.actionItems.items.first(where: {
                    if case .actionableVulnerabilities = $0.kind { return true }
                    return false
                })?.count ?? 0
                summaries.append(.init(
                    id: environment.id,
                    name: displayName,
                    online: true,
                    running: snapshot.containers.counts.runningContainers,
                    stopped: snapshot.containers.counts.stoppedContainers,
                    total: snapshot.containers.counts.totalContainers,
                    images: snapshot.imageUsageCounts.totalImages,
                    updatesAvailable: updates,
                    actionableVulnerabilities: vulnerabilities
                ))
            } catch {
                // Unreachable environment: keep the row, flag it offline.
                summaries.append(.init(
                    id: environment.id, name: displayName, online: false,
                    running: 0, stopped: 0, total: 0, images: 0,
                    updatesAvailable: 0, actionableVulnerabilities: nil
                ))
            }
        }

        let previous = WidgetSnapshotStore.load()
        WidgetSnapshotStore.save(WidgetSnapshot(
            generatedAt: Date(),
            serverConfigured: true,
            isDemo: previous?.isDemo ?? false,
            accentHex: AppGroup.defaults?.string(forKey: AppGroup.Keys.accentColorHex),
            activeEnvironmentID: IntentClientFactory.activeEnvironmentID.rawValue,
            environments: summaries,
            suggestedContainers: previous?.suggestedContainers ?? []
        ))
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
