import Foundation
import Observation
import Arcane

@MainActor
@Observable
final class ActivityCenterStore {
    private static let pageSize = 50

    private(set) var activities: [Activity] = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var isStreaming = false
    private(set) var hasMore = false
    private(set) var errorMessage: String?
    private(set) var streamErrorMessage: String?
    private(set) var environmentIDs: [String] = []

    var searchText = ""
    var statusFilter: ActivityStatusFilter = .all
    var typeFilter = ""
    var resourceFilter = ""

    private var client: ArcaneClient?
    private var limit = pageSize
    private var activityBuckets: [String: [Activity]] = [:]
    private var environmentNames: [String: String] = [:]
    private var streamTasks: [String: Task<Void, Never>] = [:]

    var filteredActivities: [Activity] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return activities.filter { activity in
            statusFilter.matches(activity)
                && (typeFilter.isEmpty || activity.type.rawValue == typeFilter)
                && (resourceFilter.isEmpty || activity.resourceType == resourceFilter)
                && (trimmed.isEmpty || matchesSearch(activity, search: trimmed))
        }
    }

    var availableTypes: [String] {
        sortedUnique(activities.map(\.type.rawValue))
    }

    var availableResourceTypes: [String] {
        sortedUnique(activities.compactMap(\.resourceType))
    }

    func configure(client: ArcaneClient?) {
        let changed = self.client == nil
        self.client = client
        if changed {
            stopStream()
            activities = []
            activityBuckets = [:]
            environmentNames = [:]
            environmentIDs = []
            limit = Self.pageSize
            hasMore = false
            errorMessage = nil
            streamErrorMessage = nil
        }
    }

    func load(reset: Bool = true, refresh: Bool = false) async {
        guard let client else { return }
        if reset {
            limit = Self.pageSize
            hasMore = false
        }
        if activities.isEmpty || refresh { isLoading = true }
        errorMessage = nil
        defer { isLoading = false }

        let environments = await resolveEnvironments(client: client)
        environmentIDs = environments.map(\.id.rawValue)
        environmentNames = Dictionary(uniqueKeysWithValues: environments.map { ($0.id.rawValue, $0.name) })

        var buckets: [String: [Activity]] = [:]
        var anyHasMore = false
        var failures = 0
        let pageLimit = limit

        await withTaskGroup(of: (ActivityEnvironment, [Activity]?).self) { group in
            for environment in environments {
                group.addTask {
                    let response = try? await client.activities.listPaginated(
                        envID: environment.id,
                        order: .descending,
                        start: 0,
                        limit: pageLimit
                    )
                    return (environment, response?.data)
                }
            }

            for await (environment, data) in group {
                guard let data else {
                    failures += 1
                    continue
                }
                let normalized = data.map { normalize($0, environment: environment) }
                buckets[environment.id.rawValue] = sortActivities(normalized)
                if data.count >= limit { anyHasMore = true }
            }
        }

        activityBuckets = buckets
        hasMore = anyHasMore
        rebuildActivities()
        if failures > 0 {
            streamErrorMessage = "Some environments could not load. Pull to refresh."
        }
    }

    func loadMore() async {
        guard !isLoadingMore, hasMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        limit += Self.pageSize
        await load(reset: false)
    }

    func startStream() {
        guard let client else { return }
        stopStream()
        streamErrorMessage = nil

        let environments = environmentIDs.map { id in
            ActivityEnvironment(
                id: EnvironmentID(rawValue: id),
                name: environmentNames[id] ?? id
            )
        }
        guard !environments.isEmpty else { return }

        isStreaming = true
        for environment in environments {
            streamTasks[environment.id.rawValue] = Task { [weak self] in
                await self?.consumeStream(client: client, environment: environment)
            }
        }
    }

    func stopStream() {
        streamTasks.values.forEach { $0.cancel() }
        streamTasks = [:]
        isStreaming = false
    }

    func cancel(_ activity: Activity, requestedBy: String?) async -> Bool {
        guard let client else { return false }
        let envID = EnvironmentID(rawValue: activity.sourceEnvironmentKey)
        do {
            let updated = try await client.activities.cancel(
                envID: envID,
                activityID: activity.id,
                requestedBy: requestedBy
            )
            upsert(normalize(updated, environment: environment(for: envID)))
            return true
        } catch {
            errorMessage = friendlyErrorMessage(error)
            return false
        }
    }

    func clearHistory(environmentIDs allowedEnvironmentIDs: Set<String>) async -> (deleted: Int64, failed: Int)? {
        guard let client else { return nil }
        let targets = environmentIDs.filter { allowedEnvironmentIDs.contains($0) }
        guard !targets.isEmpty else { return nil }

        var deleted: Int64 = 0
        var failed = 0
        await withTaskGroup(of: (Int64?, Bool).self) { group in
            for id in targets {
                group.addTask {
                    do {
                        let result = try await client.activities.clearHistory(envID: EnvironmentID(rawValue: id))
                        return (result.deleted, true)
                    } catch {
                        return (nil, false)
                    }
                }
            }
            for await result in group {
                if result.1, let count = result.0 {
                    deleted += count
                } else {
                    failed += 1
                }
            }
        }

        await load(refresh: true)
        return (deleted, failed)
    }

    private func consumeStream(client: ArcaneClient, environment: ActivityEnvironment) async {
        defer {
            streamTasks[environment.id.rawValue] = nil
            isStreaming = !streamTasks.isEmpty
        }

        do {
            for try await event in client.activities.stream(envID: environment.id, limit: Self.pageSize) {
                if Task.isCancelled { return }
                apply(event, environment: environment)
            }
        } catch {
            if Task.isCancelled { return }
            streamErrorMessage = "Live updates paused. Pull to refresh."
        }
    }

    private func apply(_ event: ActivityStreamEvent, environment: ActivityEnvironment) {
        switch event.type {
        case .snapshot:
            replaceSnapshot(event.activities, environment: environment)
        case .activity:
            if let activity = event.activity {
                upsert(normalize(activity, environment: environment))
            }
        case .message:
            if let message = event.message {
                apply(message)
            }
        case .missed:
            streamErrorMessage = "Some activity updates were missed. Pull to refresh."
        case .unknown:
            break
        }
    }

    private func replaceSnapshot(_ snapshot: [Activity], environment: ActivityEnvironment) {
        let normalized = snapshot.map { normalize($0, environment: environment) }
        activityBuckets[environment.id.rawValue] = sortActivities(normalized)
        hasMore = activityBuckets.values.contains { $0.count >= Self.pageSize }
        rebuildActivities()
    }

    private func upsert(_ activity: Activity) {
        let environmentID = activity.sourceEnvironmentKey
        var bucket = activityBuckets[environmentID] ?? []
        if let index = bucket.firstIndex(where: { $0.id == activity.id }) {
            bucket[index] = activity
        } else {
            bucket.insert(activity, at: 0)
        }
        activityBuckets[environmentID] = sortActivities(bucket).prefix(Self.pageSize).map { $0 }
        rebuildActivities()
    }

    private func apply(_ message: ActivityMessage) {
        for key in activityBuckets.keys {
            guard let index = activityBuckets[key]?.firstIndex(where: { $0.id == message.activityID }) else { continue }
            activityBuckets[key]?[index].latestMessage = message.message
            activityBuckets[key]?[index].updatedAt = message.createdAt
            break
        }
        rebuildActivities()
    }

    private func rebuildActivities() {
        activities = sortActivities(activityBuckets.values.flatMap { $0 })
    }

    private func matchesSearch(_ activity: Activity, search: String) -> Bool {
        activity.displayTitle.localizedCaseInsensitiveContains(search)
            || activity.subtitle.localizedCaseInsensitiveContains(search)
            || activity.latestMessage.localizedCaseInsensitiveContains(search)
            || activity.type.rawValue.localizedCaseInsensitiveContains(search)
            || activity.status.rawValue.localizedCaseInsensitiveContains(search)
            || (activity.sourceEnvironmentName?.localizedCaseInsensitiveContains(search) ?? false)
    }

    private func sortedUnique(_ values: [String]) -> [String] {
        Array(Set(values.filter { !$0.isEmpty })).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    private func resolveEnvironments(client: ArcaneClient) async -> [ActivityEnvironment] {
        let response = try? await client.environments.list(
            query: SearchPaginationSort(start: 0, limit: 100, sortOrder: .ascending)
        )
        let items = response?.data ?? []
        return items.map { environment in
            ActivityEnvironment(
                id: EnvironmentID(rawValue: environment.id),
                name: environment.name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? environment.id
            )
        }
    }

    private func environment(for id: EnvironmentID) -> ActivityEnvironment {
        ActivityEnvironment(id: id, name: environmentNames[id.rawValue] ?? id.rawValue)
    }

    private func normalize(_ activity: Activity, environment: ActivityEnvironment) -> Activity {
        var normalized = activity
        if normalized.sourceEnvironmentID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            normalized.sourceEnvironmentID = environment.id.rawValue
        }
        if normalized.sourceEnvironmentName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            normalized.sourceEnvironmentName = environment.name
        }
        return normalized
    }

    private func sortActivities(_ items: [Activity]) -> [Activity] {
        items.sorted { lhs, rhs in
            let lhsActive = lhs.isCancellable
            let rhsActive = rhs.isCancellable
            if lhsActive != rhsActive { return lhsActive && !rhsActive }
            return lhs.sortTime > rhs.sortTime
        }
    }
}

private struct ActivityEnvironment: Hashable, Sendable {
    var id: EnvironmentID
    var name: String
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
