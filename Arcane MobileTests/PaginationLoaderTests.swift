import Arcane
import Testing

@testable import Arcane_Mobile

@Suite
struct PaginationLoaderTests {
    @Test(arguments: [0, 20, 21, 50, 51, 101, 501])
    func collectHandlesPaginationBoundariesWithoutTruncation(total: Int) async throws {
        let resources = try await PaginationLoader.collect(pageSize: 50) { start, limit in
            let end = min(start + limit, total)
            let items = start < end
                ? (start..<end).map(TestResource.init(id:))
                : []
            return ResourcePage(
                items: items,
                pagination: .init(
                    totalPages: total == 0 ? 0 : Int64((total + limit - 1) / limit),
                    totalItems: Int64(total),
                    currentPage: (start / limit) + 1,
                    itemsPerPage: limit
                )
            )
        }

        #expect(resources.map(\.id) == Array(0..<total))
    }

    @Test
    func collectLoadsEveryPageAndDeduplicatesStableIDs() async throws {
        let items = try await PaginationLoader.collect(pageSize: 50) { start, _ in
            switch start {
            case 0:
                Self.page(start: start, items: Array(0..<50), total: 121)
            case 50:
                Self.page(start: start, items: Array(49..<100), total: 121)
            default:
                Self.page(start: start, items: Array(100..<121), total: 121)
            }
        }

        #expect(items.map(\.id) == Array(0..<121))
    }

    @Test
    func collectAdvancesUsingServerPageSize() async throws {
        let starts = PageStartRecorder()
        _ = try await PaginationLoader.collect(pageSize: 50) { start, _ in
            await starts.record(start)
            if start == 0 {
                return Self.page(start: start, items: Array(0..<49), total: 51)
            }
            return Self.page(start: start, items: [TestResource(id: 50)], total: 51)
        }

        let recordedStarts = await starts.values()
        #expect(recordedStarts == [0, 50])
    }

    @Test
    func collectUnknownTotalsStopsAfterShortPage() async throws {
        let starts = PageStartRecorder()
        let items = try await PaginationLoader.collect(pageSize: 2) { start, _ in
            await starts.record(start)
            return ResourcePage(
                items: start == 0
                    ? [TestResource(id: 1), TestResource(id: 2)]
                    : [TestResource(id: 3)],
                pagination: .init(
                    totalPages: -1,
                    totalItems: -1,
                    currentPage: (start / 2) + 1,
                    itemsPerPage: 2
                )
            )
        }

        let recordedStarts = await starts.values()
        #expect(items.map(\.id) == [1, 2, 3])
        #expect(recordedStarts == [0, 2])
    }

    @Test
    func allPagesCacheKeyCannotCollideWithFirstPageAndStillInvalidates() {
        let path = PaginationLoader.cachePath(for: "environments")

        #expect(path != "environments")
        #expect(CachedClient.matches(pattern: "environments", path: path))
    }

    @Test
    func mergeDeduplicatesAppendedPagesAndResetReplacesExistingRows() {
        let current = [TestResource(id: 1), TestResource(id: 2)]
        let incoming = [TestResource(id: 2), TestResource(id: 3)]

        #expect(
            PaginationLoader.merge(current: current, incoming: incoming, reset: false).map(\.id)
                == [1, 2, 3]
        )
        #expect(
            PaginationLoader.merge(current: current, incoming: incoming, reset: true).map(\.id)
                == [2, 3]
        )
    }

    @Test
    func progressiveStateUsesServerStrideAndRejectsStaleRefreshes() {
        var state = ProgressivePaginationState()
        let firstGeneration = state.reset()
        let acceptedFirstPage = state.receive(
            pagination: pagination(totalPages: 6, totalItems: 101, currentPage: 1, itemsPerPage: 20),
            itemCount: 20,
            requestedStart: 0,
            requestedLimit: 50,
            generation: firstGeneration
        )
        #expect(acceptedFirstPage)
        #expect(state.nextStart == 20)
        #expect(state.hasMore)
        #expect(state.totalItems == 101)

        let refreshedGeneration = state.reset()
        let acceptedStalePage = state.receive(
            pagination: pagination(totalPages: 6, totalItems: 101, currentPage: 2, itemsPerPage: 20),
            itemCount: 20,
            requestedStart: 20,
            requestedLimit: 50,
            generation: firstGeneration
        )
        #expect(!acceptedStalePage)
        #expect(state.nextStart == 0)
        #expect(!state.hasMore)
        #expect(state.totalItems == nil)
        #expect(state.accepts(refreshedGeneration))
    }

    @Test
    func progressiveStateRetainsKnownTotalWhenLaterPageOmitsIt() {
        var state = ProgressivePaginationState()
        let generation = state.reset()
        let acceptedFirstPage = state.receive(
            pagination: pagination(totalPages: 3, totalItems: 101, currentPage: 1, itemsPerPage: 50),
            itemCount: 50,
            requestedStart: 0,
            requestedLimit: 50,
            generation: generation
        )
        #expect(acceptedFirstPage)
        let acceptedSecondPage = state.receive(
            pagination: pagination(totalPages: -1, totalItems: -1, currentPage: 2, itemsPerPage: 50),
            itemCount: 50,
            requestedStart: 50,
            requestedLimit: 50,
            generation: generation
        )
        #expect(acceptedSecondPage)

        #expect(state.totalItems == 101)
    }

    @Test
    func progressiveStateKeepsFailedPageCursorForRetry() {
        var state = ProgressivePaginationState()
        let generation = state.reset()
        let acceptedFirstPage = state.receive(
            pagination: pagination(totalPages: 2, totalItems: 75, currentPage: 1, itemsPerPage: 50),
            itemCount: 50,
            requestedStart: 0,
            requestedLimit: 50,
            generation: generation
        )
        #expect(acceptedFirstPage)

        let retryStart = state.nextStart
        #expect(retryStart == 50)
        #expect(state.hasMore)

        let acceptedRetry = state.receive(
            pagination: pagination(totalPages: 2, totalItems: 75, currentPage: 2, itemsPerPage: 50),
            itemCount: 25,
            requestedStart: retryStart,
            requestedLimit: 50,
            generation: generation
        )
        #expect(acceptedRetry)
        #expect(state.nextStart == 100)
        #expect(!state.hasMore)
    }

    @Test
    func collectPropagatesLaterPageFailureInsteadOfCachingPartialResults() async {
        await #expect(throws: TestPaginationError.failedPage) {
            _ = try await PaginationLoader.collect(pageSize: 2) { start, _ in
                if start == 0 {
                    return ResourcePage(
                        items: [TestResource(id: 1), TestResource(id: 2)],
                        pagination: .init(
                            totalPages: 2,
                            totalItems: 3,
                            currentPage: 1,
                            itemsPerPage: 2
                        )
                    )
                }
                throw TestPaginationError.failedPage
            }
        }
    }

    @Test
    func collectRejectsServerTotalAboveSafetyLimit() async {
        await #expect(throws: RemoteDataLimitError.collectionTooLarge(maximumItems: 2)) {
            _ = try await PaginationLoader.collect(pageSize: 2, maximumItems: 2) { _, _ in
                ResourcePage(
                    items: [TestResource(id: 1), TestResource(id: 2)],
                    pagination: .init(totalPages: 2, totalItems: 3, currentPage: 1, itemsPerPage: 2)
                )
            }
        }
    }

    @Test
    func collectRejectsUnknownTotalWhenUniqueItemsExceedLimit() async {
        await #expect(throws: RemoteDataLimitError.collectionTooLarge(maximumItems: 2)) {
            _ = try await PaginationLoader.collect(pageSize: 2, maximumItems: 2) { start, _ in
                ResourcePage(
                    items: start == 0
                        ? [TestResource(id: 1), TestResource(id: 2)]
                        : [TestResource(id: 3)],
                    pagination: .init(
                        totalPages: -1,
                        totalItems: -1,
                        currentPage: (start / 2) + 1,
                        itemsPerPage: 2
                    )
                )
            }
        }
    }

    private static func page(start: Int, items: [Int], total: Int64) -> ResourcePage<TestResource> {
        ResourcePage(
            items: items.map(TestResource.init(id:)),
            pagination: .init(
                totalPages: max(1, (total + 49) / 50),
                totalItems: total,
                currentPage: (start / 50) + 1,
                itemsPerPage: 50
            )
        )
    }

    private static func page(
        start: Int,
        items: [TestResource],
        total: Int64
    ) -> ResourcePage<TestResource> {
        ResourcePage(
            items: items,
            pagination: .init(
                totalPages: max(1, (total + 49) / 50),
                totalItems: total,
                currentPage: (start / 50) + 1,
                itemsPerPage: 50
            )
        )
    }

    private func pagination(
        totalPages: Int64,
        totalItems: Int64,
        currentPage: Int,
        itemsPerPage: Int
    ) -> PaginationResponse {
        PaginationResponse(
            totalPages: totalPages,
            totalItems: totalItems,
            currentPage: currentPage,
            itemsPerPage: itemsPerPage
        )
    }
}

private struct TestResource: Identifiable, Sendable {
    let id: Int
}

private enum TestPaginationError: Error, Equatable {
    case failedPage
}

private actor PageStartRecorder {
    private var starts: [Int] = []

    func record(_ start: Int) {
        starts.append(start)
    }

    func values() -> [Int] {
        starts
    }
}
