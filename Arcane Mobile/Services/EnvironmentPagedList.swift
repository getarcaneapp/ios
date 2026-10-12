import Arcane
import Foundation
import Observation

/// Progressive pagination for a resource list that loads from one environment,
/// or from every enabled environment with the All Environments preview. Each
/// environment keeps its own cursor; Load More fetches the next page of every
/// environment that still has more.
@MainActor @Observable
final class EnvironmentPagedList<Value: Identifiable & Sendable> where Value.ID == String {
    typealias Fetch =
        @Sendable (_ environmentID: EnvironmentID, _ start: Int, _ limit: Int) async throws
        -> ResourcePage<Value>

    nonisolated struct PageResult: Sendable {
        let environment: ListEnvironment
        let start: Int
        let outcome: Result<ResourcePage<Value>, any Error>
    }

    private(set) var items: [EnvironmentItem<Value>] = []
    private(set) var environments: [ListEnvironment] = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    /// Set when no environment could be loaded.
    private(set) var errorMessage: String?
    private(set) var loadMoreError: String?
    /// Environments that failed while others loaded. All Environments only.
    private(set) var failedEnvironments: [EnvironmentLoadFailure] = []

    private var cursors: [EnvironmentID: ProgressivePaginationState] = [:]
    private var generation = 0
    let pageSize: Int

    init(pageSize: Int = PaginationLoader.defaultPageSize) {
        self.pageSize = pageSize
    }

    var showsAllEnvironments: Bool { environments.contains { $0.name != nil } }

    var hasMore: Bool { cursors.values.contains(where: \.hasMore) }

    /// Sum of every environment's reported total, or nil while any is unknown.
    var totalItems: Int64? {
        var total: Int64 = 0
        for environment in environments {
            guard let count = cursors[environment.id]?.totalItems else { return nil }
            total += count
        }
        return total
    }

    func reload(_ environments: [ListEnvironment], fetch: @escaping Fetch) async {
        generation &+= 1
        let request = generation
        self.environments = environments
        cursors = [:]
        isLoadingMore = false
        if items.isEmpty { isLoading = true }
        errorMessage = nil
        loadMoreError = nil
        defer { if request == generation { isLoading = false } }
        let results = await Self.fetchPages(environments.map { ($0, 0) }, limit: pageSize, fetch: fetch)
        guard request == generation else { return }
        apply(results, reset: true)
    }

    func loadMore(fetch: @escaping Fetch) async {
        guard hasMore, !isLoadingMore else { return }
        let request = generation
        isLoadingMore = true
        loadMoreError = nil
        defer { if request == generation { isLoadingMore = false } }
        let pending = environments.compactMap { environment -> (ListEnvironment, Int)? in
            guard let cursor = cursors[environment.id], cursor.hasMore else { return nil }
            return (environment, cursor.nextStart)
        }
        let results = await Self.fetchPages(pending, limit: pageSize, fetch: fetch)
        guard request == generation else { return }
        apply(results, reset: false)
    }

    /// Local edits after an action, before the follow-up reload lands.
    func update(_ body: (inout [EnvironmentItem<Value>]) -> Void) {
        body(&items)
    }

    private func apply(_ results: [PageResult], reset: Bool) {
        var incoming: [EnvironmentItem<Value>] = []
        var failures: [EnvironmentLoadFailure] = []
        for result in results {
            switch result.outcome {
            case .success(let page):
                var cursor = cursors[result.environment.id] ?? ProgressivePaginationState()
                cursor.receive(
                    pagination: page.pagination,
                    itemCount: page.items.count,
                    requestedStart: result.start,
                    requestedLimit: pageSize,
                    generation: cursor.generation
                )
                cursors[result.environment.id] = cursor
                incoming += page.items.map { EnvironmentItem($0, in: result.environment) }
            case .failure(let error):
                guard !(error is CancellationError) else { continue }
                failures.append(.init(environment: result.environment, message: friendlyErrorMessage(error)))
            }
        }

        if reset {
            // A failed environment keeps the rows it already showed.
            let failedIDs = Set(failures.map(\.environment.id))
            let kept = items.filter { failedIDs.contains($0.environmentID) }
            items = PaginationLoader.merge(current: [], incoming: incoming + kept, reset: true)
            errorMessage = !failures.isEmpty && failures.count == results.count ? failures.first?.message : nil
            failedEnvironments = showsAllEnvironments ? failures : []
        } else {
            items = PaginationLoader.merge(current: items, incoming: incoming, reset: false)
            loadMoreError = failures.first?.message
        }
    }

    nonisolated private static func fetchPages(
        _ requests: [(ListEnvironment, Int)], limit: Int, fetch: @escaping Fetch
    ) async -> [PageResult] {
        await withTaskGroup(of: (Int, PageResult).self) { group in
            var next = 0
            func enqueue() {
                guard next < requests.count else { return }
                let index = next
                let (environment, start) = requests[index]
                next += 1
                group.addTask {
                    do {
                        let page = try await fetch(environment.id, start, limit)
                        return (index, PageResult(environment: environment, start: start, outcome: .success(page)))
                    } catch {
                        return (index, PageResult(environment: environment, start: start, outcome: .failure(error)))
                    }
                }
            }
            for _ in 0..<min(4, requests.count) { enqueue() }
            var results: [(Int, PageResult)] = []
            while let result = await group.next() {
                results.append(result)
                enqueue()
            }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }
}

nonisolated struct EnvironmentLoadFailure: Identifiable, Sendable {
    let environment: ListEnvironment
    let message: String
    var id: EnvironmentID { environment.id }
}

extension EnvironmentsStore {
    /// The environments a resource list loads: `environmentID` alone, or every
    /// enabled environment when `allEnvironments` is set.
    func listEnvironments(
        _ environmentID: EnvironmentID, allEnvironments: Bool, manager: ArcaneClientManager
    ) async -> [ListEnvironment] {
        guard allEnvironments else { return [ListEnvironment(id: environmentID, name: nil)] }
        await load(manager: manager)
        return enabledEnvironments.map { ListEnvironment(id: EnvironmentID(rawValue: $0.id), name: $0.displayName) }
    }

    /// Enabled environments sorted by name, as listed in All Environments views.
    var enabledEnvironments: [Arcane.Environment] {
        environments.filter(\.enabled).sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    func displayName(for environmentID: EnvironmentID) -> String? {
        environments.first { $0.id == environmentID.rawValue }?.displayName
    }
}

extension PinnedItemsStore {
    /// Pinned item IDs (see `EnvironmentItem.id`) for a list that may mix environments.
    func pinnedIDs<Value>(kind: ItemKind, in items: [EnvironmentItem<Value>]) -> Set<String> {
        var pinnedByEnvironment: [EnvironmentID: Set<String>] = [:]
        for environmentID in Set(items.map(\.environmentID)) {
            pinnedByEnvironment[environmentID] = pinnedIDs(kind: kind, envID: environmentID)
        }
        return Set(items.filter { pinnedByEnvironment[$0.environmentID]?.contains($0.value.id) == true }.map(\.id))
    }

    func togglePin<Value>(_ item: EnvironmentItem<Value>, kind: ItemKind) {
        togglePin(item.value.id, kind: kind, envID: item.environmentID)
    }
}

extension ResourceMutationStore {
    /// Changes in any of `environments`, so an All Environments list reloads
    /// after a mutation in any environment it shows.
    func version(kind: Kind, in environments: [ListEnvironment]) -> Int {
        environments.reduce(0) { $0 &+ version(kind: kind, envID: $1.id) }
    }
}
