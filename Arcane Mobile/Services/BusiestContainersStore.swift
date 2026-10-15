import Arcane
import Foundation
import Observation

/// The Refreshed Dashboard's busiest containers. Shared across dashboard
/// instances and saved to disk, so the card opens on the last known ranking
/// and refreshes in the background instead of waiting on the server to sample
/// every environment.
@MainActor
@Observable
final class BusiestContainersStore {
    static let shared = BusiestContainersStore()

    /// Matches the server's sample cache TTL; polling faster returns the same sample.
    static let refreshInterval: Duration = .seconds(5)
    /// Per environment and sort: the card shows the top few overall, and any
    /// of them can come from a single environment.
    static let perEnvironmentLimit = 5

    struct Entry: Identifiable {
        let environmentID: EnvironmentID
        let container: ContainerSummary
        let sample: ContainerResourceSample
        var id: String { "\(environmentID.rawValue)/\(container.id)" }
    }

    private nonisolated struct Snapshot: Codable, Sendable {
        var updatedAt: Date
        /// Sort raw value → environment ID → that environment's top containers.
        var rankings: [String: [String: [ContainerSummary]]]
    }

    private var rankings: [String: [String: [ContainerSummary]]] = [:]
    /// When the shown ranking was fetched. Older than the session while it
    /// still comes from the disk cache.
    private(set) var updatedAt: Date?
    /// True once this session has received live data; until then rows are
    /// the disk cache.
    private(set) var isLive = false
    /// Environments whose server predates the shared stats collector.
    private var unsupported: Set<String> = []
    private var cacheKey: String?
    private var persistTask: Task<Void, Never>?

    /// Switches to a server/user's cache, loading its saved ranking.
    func activate(cacheKey: String) {
        guard cacheKey != self.cacheKey else { return }
        self.cacheKey = cacheKey
        rankings = [:]
        updatedAt = nil
        isLive = false
        unsupported = []
        if let snapshot = Self.load(cacheKey: cacheKey) {
            rankings = snapshot.rankings
            updatedAt = snapshot.updatedAt
        }
    }

    func top(by sort: ContainerResourceSort, limit: Int, environments: [EnvironmentID]) -> [Entry] {
        let byEnvironment = rankings[sort.rawValue] ?? [:]
        let entries = environments.flatMap { environmentID in
            (byEnvironment[environmentID.rawValue] ?? []).compactMap { container in
                container.resourceSample.map { Entry(environmentID: environmentID, container: container, sample: $0) }
            }
        }
        let value: (ContainerResourceSample) -> Double =
            switch sort {
            case .cpuUsage: { $0.cpuPercent }
            case .memoryUsage: { Double($0.memoryUsageBytes) }
            }
        return Array(entries.sorted { value($0.sample) > value($1.sample) }.prefix(limit))
    }

    /// Whether any environment has reported containers for this sort.
    func hasRanking(for sort: ContainerResourceSort) -> Bool {
        rankings[sort.rawValue]?.isEmpty == false
    }

    /// False once every listed environment reports it can't sample resources.
    func supportsAny(_ environments: [EnvironmentID]) -> Bool {
        environments.contains { !unsupported.contains($0.rawValue) }
    }

    /// Fetches each environment's top containers for both sorts. Each answer
    /// applies as it lands, so one slow environment doesn't hold back the rest;
    /// a failed one keeps its last ranking.
    func refresh(client: ArcaneClient, environments: [EnvironmentID]) async {
        let targets = environments.filter { !unsupported.contains($0.rawValue) }
        guard !targets.isEmpty else { return }
        let sorts: [ContainerResourceSort] = [.cpuUsage, .memoryUsage]
        await withTaskGroup(of: (EnvironmentID, ContainerResourceSort, ContainerListResponse?).self) { group in
            for environmentID in targets {
                for sort in sorts {
                    group.addTask {
                        let response = try? await client.containers.list(
                            envID: environmentID,
                            query: .init(
                                limit: Self.perEnvironmentLimit,
                                sortBy: sort.rawValue,
                                sortOrder: .descending
                            ),
                            includeHidden: true
                        )
                        return (environmentID, sort, response)
                    }
                }
            }
            for await (environmentID, sort, response) in group {
                guard !Task.isCancelled, let response else { continue }
                apply(response, sort: sort, environmentID: environmentID)
            }
        }
        guard !Task.isCancelled else { return }
        // Environments that dropped off the catalog leave the cache too.
        let current = Set(environments.map(\.rawValue))
        for key in rankings.keys {
            rankings[key] = rankings[key]?.filter { current.contains($0.key) }
        }
        persist()
    }

    private func apply(_ response: ContainerListResponse, sort: ContainerResourceSort, environmentID: EnvironmentID) {
        guard response.resourceSortSupported else {
            unsupported.insert(environmentID.rawValue)
            for key in rankings.keys { rankings[key]?[environmentID.rawValue] = nil }
            return
        }
        let ranked = response.data.filter { $0.resourceSample != nil }
        if rankings[sort.rawValue]?[environmentID.rawValue] != ranked {
            rankings[sort.rawValue, default: [:]][environmentID.rawValue] = ranked
        }
        updatedAt = Date()
        isLive = true
    }

    // MARK: - Disk cache

    /// Drops the in-memory ranking and every saved one (App Settings › Clear Cache).
    func clearCache() {
        persistTask?.cancel()
        rankings = [:]
        updatedAt = nil
        isLive = false
        if let directory = Self.directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func persist() {
        guard let cacheKey, let updatedAt else { return }
        let snapshot = Snapshot(updatedAt: updatedAt, rankings: rankings)
        persistTask?.cancel()
        persistTask = Task.detached(priority: .utility) {
            guard let url = Self.fileURL(cacheKey: cacheKey),
                let data = try? JSONEncoder().encode(snapshot)
            else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    private nonisolated static func load(cacheKey: String) -> Snapshot? {
        guard let url = fileURL(cacheKey: cacheKey), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    private nonisolated static var directory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("BusiestContainers", isDirectory: true)
    }

    private nonisolated static func fileURL(cacheKey: String) -> URL? {
        guard let directory else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The key holds a server URL; keep the file name to safe characters.
        let name = cacheKey.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined()
        return directory.appendingPathComponent("\(name).json")
    }
}
