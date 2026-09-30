import Foundation
import Observation
import Arcane

nonisolated enum ActivityCenterItem: Identifiable, Hashable, Sendable {
    case activity(Activity)
    case batch(ActivityBatchSummary)

    var id: String {
        switch self {
        case .activity(let activity):
            return "activity-\(activity.sourceEnvironmentKey)-\(activity.id)"
        case .batch(let batch):
            return "batch-\(batch.id)"
        }
    }

    var isActive: Bool {
        switch self {
        case .activity(let activity): activity.isCancellable
        case .batch(let batch): batch.isActive
        }
    }

    var sortTime: Date {
        switch self {
        case .activity(let activity): activity.sortTime
        case .batch(let batch): batch.sortTime
        }
    }
}

nonisolated struct ActivityBatchSummary: Identifiable, Hashable, Sendable {
    let id: String
    let activities: [Activity]

    var status: ActivityStatus {
        if activities.contains(where: \.isCancellable) { return .running }
        if activities.contains(where: { $0.status == .failed }) { return .failed }
        if activities.allSatisfy({ $0.status == .cancelled }) { return .cancelled }
        return .success
    }

    var isActive: Bool {
        activities.contains(where: \.isCancellable)
    }

    var completedCount: Int {
        activities.count(where: { !$0.isCancellable })
    }

    var failedCount: Int {
        activities.count(where: { $0.status == .failed })
    }

    var progress: Int? {
        guard !activities.isEmpty else { return nil }
        let values = activities.compactMap(\.displayProgress)
        guard values.count == activities.count else { return nil }
        return values.reduce(0, +) / values.count
    }

    var sortTime: Date {
        activities.map(\.sortTime).max() ?? .distantPast
    }

    var startedAt: Date {
        activities.map(\.startedAt).min() ?? .distantPast
    }

    var displayTitle: String {
        let types = Set(activities.map(\.type))
        if let type = types.first, types.count == 1 {
            return type.displayName
        }
        return "Related Operations"
    }

    var environmentLabel: String? {
        let names = Set(
            activities.compactMap { activity in
                activity.sourceEnvironmentName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            }
        )
        if names.count == 1 { return names.first }
        if names.count > 1 { return "\(names.count) environments" }
        return nil
    }
}

nonisolated struct ActivityHistoryClearResult: Sendable {
    let deleted: Int64
    let failed: Int
    let clearedEnvironmentIDs: Set<String>
}

nonisolated enum ActivityHistoryClearFilter {
    static func retainingActiveActivities(
        in activities: [Activity],
        clearedEnvironmentIDs: Set<String>
    ) -> [Activity] {
        activities.filter { activity in
            !clearedEnvironmentIDs.contains(activity.sourceEnvironmentKey)
                || activity.status == .queued
                || activity.status == .running
        }
    }
}

@MainActor
@Observable
final class ActivityCenterStore {
    private static let pageSize = 50
    private static let maxConcurrentEnvironmentRequests = 4
    private static let maxReconnectAttempts = 20
    private static let maxReconnectDelaySeconds: Double = 15
    /// Reset the retry budget after a stream survives long enough to be useful.
    private static let stableConnectionSeconds: TimeInterval = 5
    /// After the fast-backoff budget is spent, keep probing at this cadence
    /// forever so live updates heal on their own once the server returns.
    private static let idleRetrySeconds: Double = 30

    private(set) var activities: [Activity] = []
    private(set) var runningItems: [ActivityCenterItem] = []
    private(set) var historyItems: [ActivityCenterItem] = []
    private(set) var filteredActivityCount = 0
    private(set) var availableTypes: [String] = []
    private(set) var availableResourceTypes: [String] = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var isStreaming = false
    private(set) var hasMore = false
    private(set) var errorMessage: String?
    private(set) var loadMoreError: String?
    private(set) var streamErrorMessage: String?
    private(set) var environmentIDs: [String] = []

    var searchText = "" {
        didSet { recomputeGroupedItems() }
    }
    var statusFilter: ActivityStatusFilter = .all {
        didSet { recomputeGroupedItems() }
    }
    var typeFilter = "" {
        didSet { recomputeGroupedItems() }
    }
    var resourceFilter = "" {
        didSet { recomputeGroupedItems() }
    }

    private var client: ArcaneClient?
    private var clientTransportIdentity: ObjectIdentifier?
    private var paginationByEnvironment: [String: ProgressivePaginationState] = [:]
    private var failedPageEnvironmentIDs: Set<String> = []
    private var loadGeneration = 0
    private var activityBuckets: [String: [Activity]] = [:]
    private var activityDetails: [String: ActivityDetail] = [:]
    private var environmentNames: [String: String] = [:]
    private var streamTask: Task<Void, Never>?
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

    private func recomputeGroupedItems() {
        let filtered = filteredActivities
        filteredActivityCount = filtered.count
        let nextTypes = sortedUnique(activities.map(\.type.rawValue))
        if nextTypes != availableTypes { availableTypes = nextTypes }
        let nextResourceTypes = sortedUnique(activities.compactMap(\.resourceType))
        if nextResourceTypes != availableResourceTypes {
            availableResourceTypes = nextResourceTypes
        }
        let items = calculateGroupedItems(from: filtered)
        runningItems = items.filter(\.isActive)
        historyItems = items.filter { !$0.isActive }
    }

    private func calculateGroupedItems(from filteredActivities: [Activity]) -> [ActivityCenterItem] {
        var unbatched: [Activity] = []
        var batches: [String: [Activity]] = [:]

        for activity in filteredActivities {
            let batchID = activity.batchID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if batchID.isEmpty {
                unbatched.append(activity)
            } else {
                batches[batchID, default: []].append(activity)
            }
        }

        var items = unbatched.map(ActivityCenterItem.activity)
        for (batchID, members) in batches {
            let sortedMembers = members.sorted { $0.sortTime > $1.sortTime }
            if sortedMembers.count == 1, let activity = sortedMembers.first {
                items.append(.activity(activity))
            } else {
                items.append(.batch(ActivityBatchSummary(id: batchID, activities: sortedMembers)))
            }
        }
        return items.sorted { $0.sortTime > $1.sortTime }
    }

    func configure(client: ArcaneClient?) {
        let nextIdentity = client.map { ObjectIdentifier($0.transport) }
        let changed = nextIdentity != clientTransportIdentity
        self.client = client
        guard changed else { return }
        clientTransportIdentity = nextIdentity
        stopStream()
        activities = []
        activityBuckets = [:]
        activityDetails = [:]
        environmentNames = [:]
        environmentIDs = []
        loadGeneration += 1
        paginationByEnvironment = [:]
        failedPageEnvironmentIDs = []
        isLoading = false
        isLoadingMore = false
        hasMore = false
        errorMessage = nil
        loadMoreError = nil
        clearStreamWarning()
        recomputeGroupedItems()
    }

    func load(reset: Bool = true, refresh: Bool = false) async {
        guard let client else { return }
        loadGeneration += 1
        let generation = loadGeneration
        if reset {
            isLoadingMore = false
            loadMoreError = nil
            paginationByEnvironment = [:]
            failedPageEnvironmentIDs = []
            hasMore = false
        }
        if activities.isEmpty || refresh { isLoading = true }
        errorMessage = nil
        defer { if loadGeneration == generation { isLoading = false } }

        let environments: [ActivityEnvironment]
        do {
            environments = try await resolveEnvironments(client: client)
        } catch {
            guard loadGeneration == generation, !Task.isCancelled else { return }
            if reset { errorMessage = friendlyErrorMessage(error) }
            else { loadMoreError = friendlyErrorMessage(error) }
            return
        }
        guard loadGeneration == generation, !Task.isCancelled else { return }
        environmentIDs = environments.map(\.id.rawValue)
        environmentNames = environments.reduce(into: [:]) { names, environment in
            if names[environment.id.rawValue] == nil {
                names[environment.id.rawValue] = environment.name
            }
        }
        let requests = environments.compactMap { environment -> (ActivityEnvironment, Int)? in
            let id = environment.id.rawValue
            if paginationByEnvironment[id] == nil {
                var state = ProgressivePaginationState()
                _ = state.reset()
                paginationByEnvironment[id] = state
                failedPageEnvironmentIDs.insert(id)
            }
            guard reset || paginationByEnvironment[id]?.hasMore == true
                    || failedPageEnvironmentIDs.contains(id) else { return nil }
            return (environment, paginationByEnvironment[id]?.nextStart ?? 0)
        }
        var failures = 0
        let pageSize = Self.pageSize
        await withTaskGroup(of: (ActivityEnvironment, Int, ResourcePage<Activity>?).self) { group in
            var iterator = requests.makeIterator()
            func addRequest(_ request: (ActivityEnvironment, Int)) {
                let (environment, start) = request
                group.addTask {
                    do {
                        let response = try await client.activities.listPaginated(
                            envID: environment.id, order: .descending,
                            start: start, limit: pageSize
                        )
                        return (environment, start, ResourcePage(items: response.data, pagination: response.pagination))
                    } catch {
                        return (environment, start, nil)
                    }
                }
            }
            for _ in 0..<min(Self.maxConcurrentEnvironmentRequests, requests.count) {
                guard let request = iterator.next() else { break }
                addRequest(request)
            }
            for await (environment, start, page) in group {
                // Every completion frees a slot, including failed requests.
                if let request = iterator.next() { addRequest(request) }
                guard loadGeneration == generation, !Task.isCancelled else {
                    group.cancelAll()
                    continue
                }
                let id = environment.id.rawValue
                guard let page else {
                    failures += 1
                    failedPageEnvironmentIDs.insert(id)
                    continue
                }
                failedPageEnvironmentIDs.remove(id)
                var state = paginationByEnvironment[id] ?? ProgressivePaginationState()
                state.receive(
                    pagination: page.pagination, itemCount: page.items.count,
                    requestedStart: start, requestedLimit: Self.pageSize,
                    generation: state.generation
                )
                paginationByEnvironment[id] = state
                let normalized = page.items.map { normalize($0, environment: environment) }
                activityBuckets[id] = sortActivities(PaginationLoader.merge(
                    current: normalized, incoming: reset ? [] : activityBuckets[id] ?? [], reset: false
                ))
            }
        }
        guard loadGeneration == generation, !Task.isCancelled else { return }
        let validIDs = Set(environmentIDs)
        activityBuckets = activityBuckets.filter { validIDs.contains($0.key) }
        paginationByEnvironment = paginationByEnvironment.filter { validIDs.contains($0.key) }
        failedPageEnvironmentIDs.formIntersection(validIDs)
        hasMore = paginationByEnvironment.values.contains(where: \.hasMore)
            || !failedPageEnvironmentIDs.isEmpty
        rebuildActivities()
        if failures > 0 {
            if reset { setStreamWarning(.loadPartial) }
            else { loadMoreError = "Couldn't load more activities. Try again." }
        }
    }

    func loadMore() async {
        guard !isLoading, !isLoadingMore, hasMore else { return }
        isLoadingMore = true
        loadMoreError = nil
        let generation = loadGeneration + 1
        defer { if loadGeneration == generation { isLoadingMore = false } }
        await load(reset: false)
    }

    func detail(for activity: Activity) -> ActivityDetail? {
        activityDetails[ActivityCenterItem.activity(activity).id]
    }

    func loadDetail(_ activity: Activity) async throws {
        guard let client else { return }
        let key = ActivityCenterItem.activity(activity).id
        if activityDetails[key] == nil {
            activityDetails[key] = ActivityDetail(activity: activity, messages: [])
        }
        let previousActivity = activityDetails[key]?.activity
        let identity = clientTransportIdentity
        let response = try await client.activities.detail(
            envID: EnvironmentID(rawValue: activity.sourceEnvironmentKey),
            activityID: activity.id, limit: 500
        )
        guard identity == clientTransportIdentity, !Task.isCancelled else { return }
        let environment = environment(for: EnvironmentID(rawValue: activity.sourceEnvironmentKey))
        var current = activityDetails[key] ?? response
        // A detail request must not replace a status or progress update that
        // arrived from the stream while the request was suspended.
        if current.activity == previousActivity, response.activity.sortTime >= current.activity.sortTime {
            current.activity = normalize(response.activity, environment: environment)
            upsert(current.activity)
        }
        current.messages = PaginationLoader.merge(
            current: current.messages, incoming: response.messages, reset: false
        ).sorted { $0.createdAt < $1.createdAt }
        activityDetails[key] = current
    }

    func startStream() {
        guard let client else { return }
        stopStream()
        clearStreamWarning()

        isStreaming = true
        streamGeneration += 1
        let generation = streamGeneration
        streamTask = Task { [weak self] in
            await self?.consumeStream(client: client, generation: generation)
        }
    }

    func retryLiveUpdates() async {
        stopStream()
        clearStreamWarning()
        await load(refresh: true)
        guard !Task.isCancelled else { return }
        startStream()
    }

    func stopStream() {
        streamGeneration += 1
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
    }

    func cancel(_ activity: Activity, requestedBy: String?) async -> Bool {
        guard let client else { return false }
        let envID = EnvironmentID(rawValue: activity.sourceEnvironmentKey)
        let identity = clientTransportIdentity
        do {
            let updated = try await client.activities.cancel(
                envID: envID,
                activityID: activity.id,
                requestedBy: requestedBy
            )
            guard identity == clientTransportIdentity, !Task.isCancelled else { return false }
            upsert(normalize(updated, environment: environment(for: envID)))
            return true
        } catch {
            guard identity == clientTransportIdentity, !Task.isCancelled else { return false }
            errorMessage = friendlyErrorMessage(error)
            return false
        }
    }

    func clearHistory(
        environmentIDs allowedEnvironmentIDs: Set<String>
    ) async -> ActivityHistoryClearResult? {
        guard let client else { return nil }
        let identity = clientTransportIdentity
        let targets = environmentIDs.filter { allowedEnvironmentIDs.contains($0) }
        guard !targets.isEmpty else { return nil }

        var deleted: Int64 = 0
        var failed = 0
        var clearedEnvironmentIDs: Set<String> = []
        await withTaskGroup(of: (String, Int64?).self) { group in
            var iterator = targets.makeIterator()
            let initialBatch = min(Self.maxConcurrentEnvironmentRequests, targets.count)
            for _ in 0..<initialBatch {
                guard let id = iterator.next() else { break }
                group.addTask {
                    do {
                        let result = try await client.activities.clearHistory(envID: EnvironmentID(rawValue: id))
                        return (id, result.deleted)
                    } catch {
                        return (id, nil)
                    }
                }
            }
            for await (environmentID, count) in group {
                if let count {
                    deleted += count
                    clearedEnvironmentIDs.insert(environmentID)
                } else {
                    failed += 1
                }
                if let id = iterator.next() {
                    group.addTask {
                        do {
                            let result = try await client.activities.clearHistory(
                                envID: EnvironmentID(rawValue: id)
                            )
                            return (id, result.deleted)
                        } catch {
                            return (id, nil)
                        }
                    }
                }
            }
        }

        guard identity == clientTransportIdentity, !Task.isCancelled else { return nil }
        removeClearedHistory(environmentIDs: clearedEnvironmentIDs)
        return ActivityHistoryClearResult(
            deleted: deleted,
            failed: failed,
            clearedEnvironmentIDs: clearedEnvironmentIDs
        )
    }

    func removeClearedHistory(environmentIDs: Set<String>) {
        guard !environmentIDs.isEmpty else { return }
        for (environmentID, bucket) in activityBuckets
        where environmentIDs.contains(environmentID) {
            activityBuckets[environmentID] = ActivityHistoryClearFilter.retainingActiveActivities(
                in: bucket,
                clearedEnvironmentIDs: environmentIDs
            )
        }
        rebuildActivities()
    }

    private func consumeStream(client: ArcaneClient, generation: Int) async {
        defer {
            if generation == streamGeneration {
                streamTask = nil
                isStreaming = false
            }
        }

        var attempt = 0
        while !Task.isCancelled, generation == streamGeneration {
            let connectedAt = Date()
            var receivedFirstEvent = false
            do {
                for try await event in client.activities.stream(limit: Self.pageSize) {
                    guard generation == streamGeneration, !Task.isCancelled else { return }
                    if !receivedFirstEvent {
                        receivedFirstEvent = true
                        markStreamConnected()
                    }
                    apply(event)
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
                markStreamFailed()
                delay = Self.idleRetrySeconds
            } else {
                delay = min(pow(2, Double(attempt)), Self.maxReconnectDelaySeconds)
                attempt += 1
            }
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    private func apply(_ event: ActivityStreamEvent) {
        switch event.type {
        case .snapshot:
            applySnapshot(event)
        case .activity:
            applyActivity(event)
        case .message:
            if let message = event.message {
                apply(message, environmentID: event.environmentID)
            }
        case .missed:
            setStreamWarning(.missed)
        case .error:
            applyEnvironmentError(event)
        case .heartbeat:
            break
        case .unknown:
            break
        }
    }

    private func applySnapshot(_ event: ActivityStreamEvent) {
        guard let environmentID = event.environmentID else { return }
        let environment = environment(for: EnvironmentID(rawValue: environmentID))
        replaceSnapshot(event.activities, environment: environment)
        markEnvironmentStreamConnected(environmentID)
    }

    private func applyActivity(_ event: ActivityStreamEvent) {
        guard let activity = event.activity else { return }
        let environmentID = event.environmentID ?? activity.sourceEnvironmentKey
        let environment = environment(for: EnvironmentID(rawValue: environmentID))
        upsert(normalize(activity, environment: environment))
    }

    private func applyEnvironmentError(_ event: ActivityStreamEvent) {
        guard let environmentID = event.environmentID else { return }
        failedStreamEnvironmentIDs.insert(environmentID)
        setStreamWarning(.environmentFailure)
    }

    private func markStreamConnected() {
        if streamWarning == .persistentFailure {
            clearStreamWarning()
        }
    }

    private func markEnvironmentStreamConnected(_ environmentID: String) {
        failedStreamEnvironmentIDs.remove(environmentID)
        if failedStreamEnvironmentIDs.isEmpty, streamWarning == .environmentFailure {
            clearStreamWarning()
        }
    }

    private func markStreamFailed() {
        streamWarning = .persistentFailure
        streamErrorMessage = "Live updates paused. Pull to refresh."
    }

    private func setStreamWarning(_ warning: StreamWarning) {
        streamWarning = warning
        switch warning {
        case .loadPartial:
            streamErrorMessage = "Some environments could not load. Pull to refresh."
        case .missed:
            streamErrorMessage = "Some activity updates were missed. Pull to refresh."
        case .environmentFailure:
            streamErrorMessage = "Some environments could not provide live activity updates."
        case .persistentFailure:
            streamErrorMessage = "Live updates paused. Pull to refresh."
        }
    }

    private func clearStreamWarning() {
        streamWarning = nil
        streamErrorMessage = nil
        failedStreamEnvironmentIDs = []
    }

    private func replaceSnapshot(_ snapshot: [Activity], environment: ActivityEnvironment) {
        let normalized = snapshot.map { normalize($0, environment: environment) }
        for activity in normalized {
            let key = ActivityCenterItem.activity(activity).id
            activityDetails[key]?.activity = activity
        }
        let current = activityBuckets[environment.id.rawValue] ?? []
        let recentIDs = Set(normalized.map(\.id))
        let retained = current.filter { !recentIDs.contains($0.id) }
        activityBuckets[environment.id.rawValue] = Array(
            sortActivities(normalized + retained).prefix(max(Self.pageSize, current.count))
        )
        rebuildActivities()
    }

    private func upsert(_ activity: Activity) {
        let key = ActivityCenterItem.activity(activity).id
        activityDetails[key]?.activity = activity
        let environmentID = activity.sourceEnvironmentKey
        var bucket = activityBuckets[environmentID] ?? []
        let windowSize = max(Self.pageSize, bucket.count)
        if let index = bucket.firstIndex(where: { $0.id == activity.id }) {
            bucket[index] = activity
        } else {
            bucket.insert(activity, at: 0)
        }
        activityBuckets[environmentID] = sortActivities(bucket).prefix(windowSize).map { $0 }
        rebuildActivities()
    }

    private func apply(_ message: ActivityMessage, environmentID: String?) {
        for key in activityBuckets.keys {
            guard environmentID == nil || environmentID == key else { continue }
            guard let index = activityBuckets[key]?.firstIndex(where: { $0.id == message.activityID }) else { continue }
            activityBuckets[key]?[index].latestMessage = message.message
            activityBuckets[key]?[index].updatedAt = message.createdAt
            break
        }
        for key in activityDetails.keys {
            guard var detail = activityDetails[key], detail.activity.id == message.activityID,
                  environmentID == nil || environmentID == detail.activity.sourceEnvironmentKey else { continue }
            detail.activity.latestMessage = message.message
            detail.activity.updatedAt = message.createdAt
            detail.messages = PaginationLoader.merge(
                current: [message], incoming: detail.messages, reset: false
            ).sorted { $0.createdAt < $1.createdAt }
            activityDetails[key] = detail
        }
        rebuildActivities()
    }

    private func rebuildActivities() {
        activities = sortActivities(activityBuckets.values.flatMap { $0 })
        recomputeGroupedItems()
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

    private func resolveEnvironments(client: ArcaneClient) async throws -> [ActivityEnvironment] {
        let items: [Arcane.Environment] = try await PaginationLoader.collect(
            maximumItems: RemoteDataLimits.maximumEnvironments
        ) { start, limit in
            let response = try await client.environments.list(
                query: .init(start: start, limit: limit, sortBy: "name", sortOrder: .ascending)
            )
            return ResourcePage(items: response.data, pagination: response.pagination)
        }
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
    case environmentFailure
    case persistentFailure
}

private struct ActivityEnvironment: Hashable, Sendable {
    var id: EnvironmentID
    var name: String
}

private extension String {
    nonisolated var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
