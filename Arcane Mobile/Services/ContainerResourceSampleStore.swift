import Arcane
import Foundation
import Observation

/// Live CPU and memory for container rows, from the server's shared stats
/// collector. One resource-sorted list request per environment samples every
/// running container at once, so rows show usage under any list sort without a
/// stats socket per container.
@MainActor @Observable
final class ContainerResourceSampleStore {
    /// Matches the server's sample cache TTL; polling faster returns the same sample.
    static let refreshInterval: Duration = .seconds(5)

    private var samples: [EnvironmentID: [String: ContainerResourceSample]] = [:] {
        didSet { revision &+= 1 }
    }
    /// Bumped whenever any sample changes; resource-sorted lists reorder on it.
    private(set) var revision = 0
    /// Environments whose server predates the shared stats collector.
    private var unsupported: Set<EnvironmentID> = []

    func sample(containerID: String, in environmentID: EnvironmentID) -> ContainerResourceSample? {
        samples[environmentID]?[containerID]
    }

    /// False once the environment's server reports it can't sample resources.
    func supports(_ environmentID: EnvironmentID) -> Bool {
        !unsupported.contains(environmentID)
    }

    /// Hasn't answered yet: rows reserve space for metrics instead of jumping.
    func isPending(_ environmentID: EnvironmentID) -> Bool {
        samples[environmentID] == nil && !unsupported.contains(environmentID)
    }

    /// Refreshes every environment concurrently. A failed environment keeps
    /// its last samples so one slow poll doesn't blank the rows.
    func refresh(client: ArcaneClient, environments: [EnvironmentID]) async {
        let targets = environments.filter { !unsupported.contains($0) }
        guard !targets.isEmpty else { return }
        let results = await withTaskGroup(
            of: (EnvironmentID, ContainerListResponse?).self
        ) { group in
            for environmentID in targets {
                group.addTask {
                    let response = try? await client.containers.list(
                        envID: environmentID,
                        query: .init(
                            limit: -1,
                            sortBy: ContainerResourceSort.cpuUsage.rawValue,
                            sortOrder: .descending
                        ),
                        includeHidden: true
                    )
                    return (environmentID, response)
                }
            }
            var collected: [(EnvironmentID, ContainerListResponse?)] = []
            for await result in group { collected.append(result) }
            return collected
        }
        for (environmentID, response) in results {
            guard let response else { continue }
            guard response.resourceSortSupported else {
                unsupported.insert(environmentID)
                samples[environmentID] = nil
                continue
            }
            var byID: [String: ContainerResourceSample] = [:]
            for container in response.data {
                if let sample = container.resourceSample { byID[container.id] = sample }
            }
            if samples[environmentID] != byID { samples[environmentID] = byID }
        }
    }
}
