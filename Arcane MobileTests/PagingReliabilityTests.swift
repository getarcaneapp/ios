import Arcane
import Foundation
import Testing

@testable import Arcane_Mobile

@MainActor
@Suite("Paging and activity reliability")
struct PagingReliabilityTests {
    @Test
    func activitiesRefillFailedSlotsAndRetryOnlyFailedEnvironmentCursors() async throws {
        let requests = PagingRequestRecorder()
        let server = PagingTestServer { request in
            let path = request.url!.path
            if path == "/api/environments" {
                return (
                    200,
                    try pagingEnvelope(
                        (0..<7).map {
                            Arcane.Environment(id: "env\($0)", name: "Environment \($0)", apiUrl: "", status: "online")
                        }, stride: 50, total: 7)
                )
            }
            let environment = path.split(separator: "/")[2].description
            let start = pagingStart(request)
            let attempt = requests.record(environment, start: start)
            if ["env0", "env1", "env2", "env3"].contains(environment), attempt == 1 {
                return (400, Data(#"{"error":"temporarily unavailable"}"#.utf8))
            }
            return (
                200,
                try pagingEnvelope([pagingActivity(id: environment, environment: environment)], stride: 20, total: 1)
            )
        }
        defer { server.close() }
        let store = ActivityCenterStore()
        store.configure(client: server.client())
        await store.load()
        #expect(Set(requests.environmentIDs) == Set((0..<7).map { "env\($0)" }))
        #expect(Set(store.activities.map(\.id)) == ["env4", "env5", "env6"])
        #expect(store.hasMore)
        await store.loadMore()
        #expect(store.activities.count == 7)
        #expect(!store.hasMore)
        #expect(requests.starts(for: "env0") == [0, 0])
        #expect(requests.starts(for: "env4") == [0])
    }

    @Test
    func expandedActivityHistorySurvivesRecentSnapshotAndUpdate() async throws {
        let server = PagingTestServer { request in
            if request.url!.path == "/api/environments" {
                return (
                    200,
                    try pagingEnvelope(
                        [
                            Arcane.Environment(id: "one", name: "One", apiUrl: "", status: "online")
                        ], stride: 50, total: 1)
                )
            }
            if ["/api/activities/stream", "/api/stream"].contains(request.url!.path) {
                let snapshot = ActivityStreamEvent(
                    type: .snapshot, environmentID: "one",
                    activities: (0..<50).map { pagingActivity(id: "a\($0)") }, timestamp: .now)
                var updated = pagingActivity(id: "a0")
                updated.latestMessage = "live update received"
                let update = ActivityStreamEvent(
                    type: .activity, environmentID: "one", activity: updated, timestamp: .now)
                let multiplexed = request.url!.path == "/api/stream"
                return (
                    200,
                    try pagingStreamLine(snapshot, multiplexed: multiplexed)
                        + pagingStreamLine(update, multiplexed: multiplexed)
                )
            }
            let start = pagingStart(request)
            return (
                200,
                try pagingEnvelope(
                    (start..<min(start + 50, 100)).map {
                        pagingActivity(id: "a\($0)")
                    }, stride: 50, total: 100)
            )
        }
        defer { server.close() }
        let store = ActivityCenterStore()
        store.configure(client: server.client())
        await store.load()
        await store.loadMore()
        #expect(store.activities.count == 100)
        store.startStream()
        defer { store.stopStream() }
        for _ in 0..<200 {
            if store.activities.first(where: { $0.id == "a0" })?.latestMessage == "live update received" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.activities.first(where: { $0.id == "a0" })?.latestMessage == "live update received")
        #expect(store.activities.count == 100)
        #expect(store.activities.contains(where: { $0.id == "a90" }))
        #expect(!store.hasMore)
    }

    @Test
    func cancelledActivityLoadDoesNotRestartLiveUpdates() async {
        let server = PagingTestServer { _ in
            (400, Data(#"{"error":"cancelled load"}"#.utf8))
        }
        defer { server.close() }
        let store = ActivityCenterStore()
        store.configure(client: server.client())
        let task = Task { await store.retryLiveUpdates() }
        task.cancel()
        await task.value
        #expect(!store.isStreaming)
    }

    @Test
    func activityDetailKeepsIntermediateProgressThroughMessageUpdates() async throws {
        var activity = pagingActivity(id: "progress")
        activity.status = .running
        activity.progress = 45
        let halfway = activity
        let message = ActivityMessage(
            id: "line", activityID: halfway.id, level: .info,
            message: "Still working", createdAt: halfway.startedAt.addingTimeInterval(1))
        let server = PagingTestServer { request in
            if request.url!.path.hasSuffix("/stream") {
                let update = ActivityStreamEvent(
                    type: .activity, environmentID: "one", activity: halfway, timestamp: message.createdAt)
                let output = ActivityStreamEvent(
                    type: .message, environmentID: "one", message: message, timestamp: message.createdAt)
                return (
                    200, try pagingStreamLine(update, multiplexed: true) + pagingStreamLine(output, multiplexed: true)
                )
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            return (200, try encoder.encode(PagingDetailEnvelope(data: ActivityDetail(activity: halfway))))
        }
        defer { server.close() }
        let store = ActivityCenterStore()
        store.configure(client: server.client())
        try await store.loadDetail(halfway)
        store.startStream()
        defer { store.stopStream() }
        for _ in 0..<200 {
            if store.detail(for: halfway)?.messages.count == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.detail(for: halfway)?.messages.count == 1)
        #expect(store.detail(for: halfway)?.activity.displayProgress == 45)
        #expect(store.detail(for: halfway)?.activity.status == .running)
        #expect(store.runningItems.count == 1)
        #expect(store.historyItems.isEmpty)
    }

    @Test
    func activityDetailFollowsStatusAndMessagesWithoutRefresh() async throws {
        var running = pagingActivity(id: "running")
        running.status = .running
        running.progress = 10
        let initial = running
        var completed = running
        completed.status = .success
        completed.progress = 100
        completed.endedAt = initial.startedAt.addingTimeInterval(60)
        completed.updatedAt = completed.endedAt
        let terminal = completed
        let message = ActivityMessage(
            id: "message", activityID: initial.id,
            level: .success, message: "Deployment finished", createdAt: terminal.endedAt!)
        let server = PagingTestServer { request in
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if request.url!.path.hasSuffix("/stream") {
                let events = [
                    ActivityStreamEvent(
                        type: .snapshot, environmentID: "one", activities: [initial], timestamp: initial.startedAt),
                    ActivityStreamEvent(
                        type: .message, environmentID: "one", message: message, timestamp: message.createdAt),
                    ActivityStreamEvent(
                        type: .activity, environmentID: "one", activity: terminal, timestamp: message.createdAt),
                ]
                return (
                    200,
                    try events.reduce(into: Data()) { data, event in
                        data += try pagingStreamLine(event, multiplexed: request.url!.path == "/api/stream")
                    }
                )
            }
            return (200, try encoder.encode(PagingDetailEnvelope(data: ActivityDetail(activity: initial))))
        }
        defer { server.close() }
        let store = ActivityCenterStore()
        store.configure(client: server.client())
        try await store.loadDetail(initial)
        #expect(store.detail(for: initial)?.activity.status == .running)
        store.startStream()
        defer { store.stopStream() }
        // Stream events rebuild the grouped lists in coalesced batches, so
        // wait for the list as well as the detail.
        for _ in 0..<200 {
            if store.detail(for: initial)?.activity.status == .success, store.historyItems.count == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.detail(for: initial)?.activity.status == .success)
        #expect(store.detail(for: initial)?.activity.progress == 100)
        #expect(store.detail(for: initial)?.activity.endedAt == terminal.endedAt)
        #expect(store.detail(for: initial)?.messages.map(\.id) == [message.id])
        #expect(store.runningItems.isEmpty)
        #expect(store.historyItems.count == 1)
        // A retry of the old detail response still preserves streamed messages.
        try await store.loadDetail(initial)
        #expect(store.detail(for: initial)?.messages.count == 1)
        #expect(store.detail(for: initial)?.activity.status == .success)
        store.configure(client: nil)
        #expect(store.detail(for: initial) == nil)
    }

    @Test
    func templatesUseClampedStrideWithUnknownTotalsAndFailedPageRetry() async throws {
        let requests = PagingRequestRecorder()
        let server = PagingTestServer { request in
            let start = pagingStart(request)
            let attempt = requests.record("templates", start: start)
            if start == 20 && attempt == 2 { return (400, Data(#"{"error":"retry"}"#.utf8)) }
            let ids = start == 0 ? Array(0..<20) : Array(19..<25)
            return (
                200,
                try pagingEnvelope(
                    ids.map {
                        Template(
                            id: "t\($0)", name: "Template \($0)", description: "", content: "", isCustom: true,
                            isRemote: false)
                    }, stride: 20, total: -1)
            )
        }
        defer { server.close() }
        let store = TemplateBrowserStore()
        store.configure(client: server.client())
        await store.reload()
        #expect(store.hasMore)
        await store.loadMore()
        #expect(store.loadMoreError != nil)
        #expect(store.templates.count == 20)
        await store.loadMore()
        #expect(store.templates.count == 25)
        #expect(Set(store.templates.map(\.id)).count == 25)
        #expect(requests.starts(for: "templates") == [0, 20, 20])
        #expect(!store.hasMore)
    }

    @Test
    func eventsAdvanceByServerStrideAfterDuplicateRows() async throws {
        let requests = PagingRequestRecorder()
        let server = PagingTestServer { request in
            let start = pagingStart(request)
            _ = requests.record("events", start: start)
            let ids = start == 0 ? Array(0..<20) : (start == 20 ? Array(19..<39) : [39, 40])
            return (
                200,
                try pagingEnvelope(
                    ids.map {
                        Event(
                            id: "e\($0)", type: "test", severity: "info", title: "Event", timestamp: .now,
                            createdAt: .now)
                    }, stride: 20, total: 41)
            )
        }
        defer { server.close() }
        let store = EventsStore()
        store.configure(client: server.client())
        await store.reload()
        await store.loadMore()
        await store.loadMore()
        #expect(requests.starts(for: "events") == [0, 20, 40])
        #expect(store.events.count == 41)
        #expect(!store.hasMore)
    }
}

private func pagingStart(_ request: URLRequest) -> Int {
    let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
    return Int(query?.first(where: { $0.name == "start" })?.value ?? "0") ?? 0
}

private func pagingActivity(id: String, environment: String = "one") -> Activity {
    Activity(
        id: id, environmentID: environment, type: .autoUpdate, status: .success,
        startedAt: Date(timeIntervalSince1970: 1_700_000_000), createdAt: Date(timeIntervalSince1970: 1_700_000_000))
}

private struct PagingEnvelope<T: Encodable>: Encodable {
    let success = true
    let data: [T]
    let pagination: PaginationResponse
}

private struct PagingDetailEnvelope: Encodable {
    let success = true
    let data: ActivityDetail
}

private struct PagingActivityStreamEnvelope: Encodable {
    let channel = "activities"
    let activity: ActivityStreamEvent
    let timestamp: Date
}

private func pagingStreamLine(_ event: ActivityStreamEvent, multiplexed: Bool) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data =
        try multiplexed
        ? encoder.encode(PagingActivityStreamEnvelope(activity: event, timestamp: event.timestamp))
        : encoder.encode(event)
    return data + Data([10])
}

private func pagingEnvelope<T: Encodable>(_ items: [T], stride: Int, total: Int64) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(
        PagingEnvelope(
            data: items,
            pagination: .init(
                totalPages: total < 0 ? -1 : max(1, (total + Int64(stride) - 1) / Int64(stride)),
                totalItems: total, currentPage: 1, itemsPerPage: stride
            )))
}

private final class PagingRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [String: [Int]] = [:]
    var environmentIDs: [String] { lock.withLock { Array(requests.keys) } }
    func starts(for key: String) -> [Int] { lock.withLock { requests[key] ?? [] } }
    func record(_ key: String, start: Int) -> Int {
        lock.withLock {
            requests[key, default: []].append(start)
            return requests[key]?.count ?? 0
        }
    }
}

private struct PagingTestServer {
    let host = UUID().uuidString.lowercased() + ".test"
    init(handler: @Sendable @escaping (URLRequest) throws -> (Int, Data)) {
        PagingReliabilityURLProtocol.registry.register(host, handler: handler)
    }
    func client() -> ArcaneClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PagingReliabilityURLProtocol.self]
        return ArcaneClient(
            configuration: .init(
                baseURL: URL(string: "https://\(host)")!,
                urlSession: URLSession(configuration: configuration),
                retryPolicy: .init(maxAttempts: 1, baseBackoff: .zero, maxBackoff: .zero)))
    }
    func close() { PagingReliabilityURLProtocol.registry.remove(host) }
}

private final class PagingHandlerRegistry: @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, Data)
    private let lock = NSLock()
    private var handlers: [String: Handler] = [:]
    func register(_ host: String, handler: @escaping Handler) { lock.withLock { handlers[host] = handler } }
    func remove(_ host: String) { lock.withLock { _ = handlers.removeValue(forKey: host) } }
    func handler(for host: String) -> Handler? { lock.withLock { handlers[host] } }
}

private final class PagingReliabilityURLProtocol: URLProtocol, @unchecked Sendable {
    static let registry = PagingHandlerRegistry()
    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.registry.handler(for: request.url?.host ?? "") else { throw URLError(.badURL) }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil,
                headerFields: [
                    "Content-Type": request.url?.path.hasSuffix("stream") == true
                        ? "application/x-ndjson" : "application/json"
                ])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor @Suite("All environments preview loading")
struct EnvironmentPagedListTests {
    private static func gitOpsPage(_ client: ArcaneClient) -> EnvironmentPagedList<DynamicResource>.Fetch {
        { environmentID, start, limit in
            let response: PaginatedResponse<DynamicResource> = try await client.rest.paginated(
                client.rest.environmentPath(environmentID, "gitops-syncs"), start: start, limit: limit)
            return ResourcePage(items: response.data, pagination: response.pagination)
        }
    }

    private static let twoEnvironments = [
        ListEnvironment(id: "one", name: "One"), ListEnvironment(id: "two", name: "Two"),
    ]

    @Test func keepsDuplicateIDsAcrossEnvironmentsAndPagesEachEnvironment() async throws {
        let requests = PagingRequestRecorder()
        let server = PagingTestServer { request in
            let environment = request.url!.path.split(separator: "/")[2].description
            let start = pagingStart(request)
            _ = requests.record(environment, start: start)
            let items = (start..<min(start + 2, 3)).map {
                DynamicResource(id: "shared-\($0)", values: ["id": .string("shared-\($0)")])
            }
            return (200, try pagingEnvelope(items, stride: 2, total: 3))
        }
        defer { server.close() }
        let fetch = Self.gitOpsPage(server.client())
        let list = EnvironmentPagedList<DynamicResource>(pageSize: 2)
        await list.reload(Self.twoEnvironments, fetch: fetch)
        #expect(list.items.count == 4)
        #expect(list.hasMore)
        #expect(list.totalItems == 6)
        await list.loadMore(fetch: fetch)
        #expect(list.items.count == 6)
        #expect(!list.hasMore)
        #expect(Set(list.items.map(\.id)).count == 6)
        #expect(list.items.filter { $0.value.id == "shared-0" }.map(\.environmentID) == ["one", "two"])
        #expect(requests.starts(for: "one") == [0, 2])
        #expect(requests.starts(for: "two") == [0, 2])
    }

    @Test(arguments: [403, 500, 504])
    func oneFailureDoesNotHideOtherEnvironments(status: Int) async throws {
        let server = PagingTestServer { request in
            let environment = request.url!.path.split(separator: "/")[2].description
            if environment == "env1" { return (status, Data(#"{"error":"Environment unavailable"}"#.utf8)) }
            return (
                200,
                try pagingEnvelope([DynamicResource(id: "same", values: ["id": .string("same")])], stride: 50, total: 1)
            )
        }
        defer { server.close() }
        let environments = (0..<6).map { ListEnvironment(id: EnvironmentID(rawValue: "env\($0)"), name: "Env \($0)") }
        let list = EnvironmentPagedList<DynamicResource>()
        await list.reload(environments, fetch: Self.gitOpsPage(server.client()))
        #expect(list.items.count == 5)
        #expect(list.errorMessage == nil)
        #expect(list.failedEnvironments.map(\.environment.id) == ["env1"])
    }

    @Test func singleEnvironmentKeepsResourceIDsAndReportsFailures() async throws {
        let status = PagingRequestRecorder()
        let server = PagingTestServer { _ in
            if status.record("calls", start: 0) > 1 { return (500, Data(#"{"error":"Unavailable"}"#.utf8)) }
            return (
                200,
                try pagingEnvelope(
                    [DynamicResource(id: "visible", values: ["id": .string("visible")])], stride: 50, total: 1)
            )
        }
        defer { server.close() }
        let fetch = Self.gitOpsPage(server.client())
        let list = EnvironmentPagedList<DynamicResource>()
        await list.reload([ListEnvironment(id: "one", name: nil)], fetch: fetch)
        #expect(list.items.map(\.id) == ["visible"])
        #expect(!list.showsAllEnvironments)
        // A failed refresh keeps the rows already shown.
        await list.reload([ListEnvironment(id: "one", name: nil)], fetch: fetch)
        #expect(list.items.map(\.id) == ["visible"])
        #expect(list.errorMessage != nil)
        #expect(list.failedEnvironments.isEmpty)
    }

    @Test func refreshKeepsVisibleRowsUntilReplacementArrives() async throws {
        let server = PagingTestServer { _ in
            (
                200,
                try pagingEnvelope(
                    [DynamicResource(id: "visible", values: ["id": .string("visible")])], stride: 50, total: 1)
            )
        }
        defer { server.close() }
        let client = server.client()
        let list = EnvironmentPagedList<DynamicResource>()
        await list.reload(Self.twoEnvironments, fetch: Self.gitOpsPage(client))
        let checks = PagingRequestRecorder()
        await list.reload(Self.twoEnvironments) { environmentID, start, limit in
            let visible = await MainActor.run { list.items.count == 2 && !list.isLoading }
            _ = checks.record(visible ? "visible" : "hidden", start: start)
            return try await Self.gitOpsPage(client)(environmentID, start, limit)
        }
        #expect(checks.starts(for: "visible").count == 2)
        #expect(checks.starts(for: "hidden").isEmpty)
        #expect(list.items.count == 2)
    }
}

@MainActor @Suite("Environment colors")
struct EnvironmentColorTests {
    @Test func defaultsAreUniquePersistentAndCustomDuplicatesAreRejected() throws {
        let suite = "environment-colors-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = EnvironmentColorStore(defaults: defaults)
        let ids = (0..<30).map(String.init)
        store.assignDefaults(server: "https://one.example", environmentIDs: ids)
        let colors = ids.compactMap { store.hex(server: "https://one.example", environmentID: $0) }
        #expect(colors.count == ids.count)
        #expect(Set(colors).count == ids.count)
        #expect(!store.set(colors[0].lowercased(), server: "https://one.example", environmentID: ids[1]))
        #expect(store.set(colors[0], server: "https://two.example", environmentID: ids[1]))
        store.set(nil, server: "https://one.example", environmentID: ids[1])
        #expect(Set(ids.compactMap { store.hex(server: "https://one.example", environmentID: $0) }).count == ids.count)
        let restored = EnvironmentColorStore(defaults: defaults)
        restored.assignDefaults(server: "https://one.example", environmentIDs: ids.reversed())
        #expect(
            ids.map { restored.hex(server: "https://one.example", environmentID: $0) }
                == ids.map { store.hex(server: "https://one.example", environmentID: $0) })
    }
}

@MainActor @Suite("All environments operations")
struct AllEnvironmentsOperationTests {
    @Test func visitsEveryEnabledEnvironmentAndContinuesAfterFailure() async {
        var disabled = Arcane.Environment(id: "disabled", name: "Disabled", apiUrl: "", status: "offline")
        disabled.enabled = false
        let environments = [
            Arcane.Environment(id: "one", name: "One", apiUrl: "", status: "online"),
            .init(id: "two", name: "Two", apiUrl: "", status: "online"), disabled,
        ]
        let store = AllEnvironmentsOperationStore()
        var visited: [String] = []
        await store.run(environments: environments, isCurrent: { true }) { id in
            visited.append(id.rawValue)
            if id.rawValue == "one" { throw ArcaneError.transport("Offline") }
            return "Done"
        }
        #expect(visited == ["one", "two"])
        #expect(store.results.map(\.failed) == [true, false])
        #expect(store.results.allSatisfy { $0.finished })
        #expect(!store.isRunning)
        await store.run(environments: environments, isCurrent: { true }) { id in
            visited.append(id.rawValue)
            return "Repeated"
        }
        #expect(visited == ["one", "two"])
    }

    @Test func connectionChangeStopsRemainingMutations() async {
        let environments = [
            Arcane.Environment(id: "one", name: "One", apiUrl: "", status: "online"),
            .init(id: "two", name: "Two", apiUrl: "", status: "online"),
        ]
        let store = AllEnvironmentsOperationStore()
        var current = true
        var visited: [String] = []
        await store.run(environments: environments, isCurrent: { current }) { id in
            visited.append(id.rawValue)
            current = false
            return "Done"
        }
        #expect(visited == ["one"])
        #expect(store.results[1].failed)
        #expect(store.results[1].status.hasPrefix("Not started"))
    }
}

@MainActor @Suite("All environments toast feedback", .serialized)
struct AllEnvironmentsToastFeedbackTests {
    @Test func partialFailureStillReportsAfterAnotherToastReplacesProgress() async {
        let environments = [
            Arcane.Environment(id: "one", name: "One", apiUrl: "", status: "online"),
            Arcane.Environment(id: "two", name: "Two", apiUrl: "", status: "online"),
        ]
        let store = AllEnvironmentsOperationStore()
        await store.runWithToast(title: "Check for Updates", environments: environments, isCurrent: { true }) { id in
            if id.rawValue == "one" {
                #expect(ToastPresenter.shared.currentToast?.activityState == nil)
                #expect(ToastPresenter.shared.currentToast?.isPersistent == true)
            }
            showToast(.info("Another activity"))
            if id.rawValue == "one" { throw ArcaneError.transport("Offline") }
            return "Done"
        }
        #expect(store.results.map(\.failed) == [true, false])
        #expect(ToastPresenter.shared.currentToast?.title.contains("1 succeeded, 1 failed") == true)
        #expect(!store.isRunning)
        dismissToast()
    }

    @Test func duplicateRunIsBlockedAndLaterConfirmedRunCanStart() async {
        let environments = [Arcane.Environment(id: "one", name: "One", apiUrl: "", status: "online")]
        let store = AllEnvironmentsOperationStore()
        var calls = 0
        await store.runWithToast(title: "Update All", environments: environments, isCurrent: { true }) { _ in
            calls += 1
            await store.runWithToast(title: "Duplicate", environments: environments, isCurrent: { true }) { _ in
                calls += 100
                return "Unexpected"
            }
            return "Done"
        }
        #expect(calls == 1)
        await store.runWithToast(title: "Update All", environments: environments, isCurrent: { true }) { _ in
            calls += 1
            return "Done"
        }
        #expect(calls == 2)
        #expect(store.results.count == 1)
        #expect(ToastPresenter.shared.currentToast?.title == "Update All complete")
        dismissToast()
    }
}

private struct PagingImageUpdatesEnvelope: Encodable {
    let success = true
    let data: [String: ImageUpdateInfo]
}

@MainActor @Suite("Resource pruning and All Environments actions")
struct AllEnvironmentsResourceActionTests {
    @Test(arguments: ResourcePruneAction.allCases)
    func prunesOnlyTheRequestedResourceInEveryEnabledEnvironment(_ action: ResourcePruneAction) async throws {
        let requests = PagingRequestRecorder()
        let suffix = action == .containers ? "system/prune" : "\(action.resourceName)/prune"
        let images = action == .images || action == .unusedImages
        let imageMode = action == .unusedImages ? "all" : "dangling"
        let containers = action == .containers
        let server = PagingTestServer { request in
            #expect(request.httpMethod == "POST")
            let path = try #require(request.url?.path)
            let environment = path.split(separator: "/")[2].description
            #expect(path == "/api/environments/\(environment)/\(suffix)")
            _ = requests.record(environment, start: 0)
            if images || containers {
                let body = try resourceActionBody(request)
                if images {
                    #expect(Set(body.keys) == ["mode"])
                    #expect(body["mode"] as? String == imageMode)
                } else {
                    #expect(Set(body.keys) == ["containers"])
                    #expect((body["containers"] as? [String: String]) == ["mode": "stopped"])
                }
            }
            return (
                200,
                Data(
                    #"{"success":true,"data":{"success":true,"spaceReclaimed":0,"imagesDeleted":[],"volumesDeleted":[],"networksDeleted":[]}}"#
                        .utf8)
            )
        }
        defer { server.close() }
        let client = server.client()
        var disabled = Arcane.Environment(id: "disabled", name: "Disabled", apiUrl: "", status: "online")
        disabled.enabled = false
        let store = AllEnvironmentsOperationStore()
        await store.run(
            environments: [
                .init(id: "one", name: "One", apiUrl: "", status: "online"), disabled,
                .init(id: "two", name: "Two", apiUrl: "", status: "offline"),
            ], isCurrent: { true }
        ) { id in
            try await action.perform(client: client, environmentID: id)
            return "Done"
        }
        #expect(Set(requests.environmentIDs) == ["one", "two"])
        #expect(store.results.count == 2)
        #expect(store.results.allSatisfy { $0.finished && !$0.failed })
    }

    @Test func environmentItemsStayDistinctOnlyInAllEnvironmentsLists() {
        let image = ImageSummary(id: "shared", repoTags: ["app:latest"])
        let single = EnvironmentItem(image, in: ListEnvironment(id: "one", name: nil))
        let one = EnvironmentItem(image, in: ListEnvironment(id: "one", name: "One"))
        let two = EnvironmentItem(image, in: ListEnvironment(id: "two", name: "Two"))
        #expect(single.id == "shared")
        #expect(one.id != two.id)
        #expect(one.value.id == two.value.id)
        #expect(two.environmentID == "two")
    }
}

private func resourceActionBody(_ request: URLRequest) throws -> [String: Any] {
    var data = request.httpBody ?? Data()
    if let stream = request.httpBodyStream {
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}
