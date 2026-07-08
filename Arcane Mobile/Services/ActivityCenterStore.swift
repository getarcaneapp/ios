import Foundation
import Observation
import Arcane

@MainActor
@Observable
final class ActivityCenterStore {
    private static let pageSize = 50
    private static let maxReconnectAttempts = 20
    private static let maxReconnectDelaySeconds: Double = 15
    /// Reset the retry budget after a stream survives long enough to be useful.
    private static let stableConnectionSeconds: TimeInterval = 5
    /// After the fast-backoff budget is spent, keep probing at this cadence
    /// forever so live updates heal on their own once the server returns.
    private static let idleRetrySeconds: Double = 30

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
    private var failedStreamEnvironmentIDs: Set<String> = []
    private var streamWarning: StreamWarning?
    /// Bumped on every stream start/stop so a finishing task from a previous
    /// stream generation can't mutate the current state.
    private var streamGeneration = 0

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
            clearStreamWarning()
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
            setStreamWarning(.loadPartial)
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
        clearStreamWarning()

        let environments = environmentIDs.map { id in
            ActivityEnvironment(
                id: EnvironmentID(rawValue: id),
                name: environmentNames[id] ?? id
            )
        }
        guard !environments.isEmpty else { return }

        isStreaming = true
        streamGeneration += 1
        let generation = streamGeneration
        for environment in environments {
            streamTasks[environment.id.rawValue] = Task { [weak self] in
                await self?.consumeStream(client: client, environment: environment, generation: generation)
            }
        }
    }

    func retryLiveUpdates() async {
        stopStream()
        clearStreamWarning()
        await load(refresh: true)
        startStream()
    }

    func stopStream() {
        streamGeneration += 1
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

    private func consumeStream(client: ArcaneClient, environment: ActivityEnvironment, generation: Int) async {
        defer {
            // Only clean up our own entry — a stale task finishing after a
            // restart must not remove the current generation's task.
            if generation == streamGeneration {
                streamTasks[environment.id.rawValue] = nil
                isStreaming = !streamTasks.isEmpty
            }
        }

        var attempt = 0
        while !Task.isCancelled, generation == streamGeneration {
            let connectedAt = Date()
            var receivedFirstEvent = false
            do {
                for try await event in client.activities.stream(envID: environment.id, limit: Self.pageSize) {
                    guard generation == streamGeneration, !Task.isCancelled else { return }
                    if !receivedFirstEvent {
                        receivedFirstEvent = true
                        markStreamConnected(environment)
                    }
                    apply(event, environment: environment)
                }
            } catch is CancellationError {
                return
            } catch {
                // Transport drops, server restarts, and NDJSON decode failures
                // are retried below. The user-facing warning is only shown when
                // this environment exhausts the reconnect budget.
            }

            guard generation == streamGeneration, !Task.isCancelled else { return }

            if receivedFirstEvent, Date().timeIntervalSince(connectedAt) >= Self.stableConnectionSeconds {
                attempt = 0
            }
            // Exponential backoff while the budget lasts, then a slow idle
            // probe forever — the "paused" banner stays honest, but the
            // stream recovers on its own instead of staying dead until the
            // app is relaunched.
            let delay: Double
            if attempt >= Self.maxReconnectAttempts {
                markStreamFailed(environment)
                delay = Self.idleRetrySeconds
            } else {
                delay = min(pow(2, Double(attempt)), Self.maxReconnectDelaySeconds)
                attempt += 1
            }
            try? await Task.sleep(for: .seconds(delay))
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
            setStreamWarning(.missed)
        case .unknown:
            break
        }
    }

    private func markStreamConnected(_ environment: ActivityEnvironment) {
        failedStreamEnvironmentIDs.remove(environment.id.rawValue)
        if streamWarning == .persistentFailure {
            updatePersistentStreamWarning()
        }
    }

    private func markStreamFailed(_ environment: ActivityEnvironment) {
        failedStreamEnvironmentIDs.insert(environment.id.rawValue)
        updatePersistentStreamWarning()
    }

    private func updatePersistentStreamWarning() {
        guard !failedStreamEnvironmentIDs.isEmpty else {
            if streamWarning == .persistentFailure {
                clearStreamWarning()
            }
            return
        }

        streamWarning = .persistentFailure
        if !environmentIDs.isEmpty, failedStreamEnvironmentIDs.count >= environmentIDs.count {
            streamErrorMessage = "Live updates paused. Pull to refresh."
        } else {
            streamErrorMessage = "Some live updates paused. Pull to refresh."
        }
    }

    private func setStreamWarning(_ warning: StreamWarning) {
        streamWarning = warning
        switch warning {
        case .loadPartial:
            streamErrorMessage = "Some environments could not load. Pull to refresh."
        case .missed:
            streamErrorMessage = "Some activity updates were missed. Pull to refresh."
        case .persistentFailure:
            updatePersistentStreamWarning()
        }
    }

    private func clearStreamWarning() {
        streamWarning = nil
        streamErrorMessage = nil
        failedStreamEnvironmentIDs = []
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

private enum StreamWarning {
    case loadPartial
    case missed
    case persistentFailure
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
