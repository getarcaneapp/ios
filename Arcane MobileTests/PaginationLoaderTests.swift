import Arcane
import XCTest

@testable import Arcane_Mobile

nonisolated final class PaginationLoaderTests: XCTestCase {
    func testCollectHandlesPaginationBoundariesWithoutTruncation() async throws {
        for total in [0, 20, 21, 50, 51, 101, 501] {
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

            XCTAssertEqual(resources.map(\.id), Array(0..<total))
        }
    }

    func testCollectLoadsEveryPageAndDeduplicatesStableIDs() async throws {
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

        XCTAssertEqual(items.map(\.id), Array(0..<121))
    }

    func testCollectAdvancesUsingServerPageSize() async throws {
        let starts = PageStartRecorder()
        _ = try await PaginationLoader.collect(pageSize: 50) { start, _ in
            await starts.record(start)
            if start == 0 {
                return Self.page(start: start, items: Array(0..<49), total: 51)
            }
            return Self.page(start: start, items: [TestResource(id: 50)], total: 51)
        }

        let recordedStarts = await starts.values()
        XCTAssertEqual(recordedStarts, [0, 50])
    }

    func testCollectUnknownTotalsStopsAfterShortPage() async throws {
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
        XCTAssertEqual(items.map(\.id), [1, 2, 3])
        XCTAssertEqual(recordedStarts, [0, 2])
    }

    func testAllPagesCacheKeyCannotCollideWithFirstPageAndStillInvalidates() {
        let path = PaginationLoader.cachePath(for: "environments")

        XCTAssertNotEqual(path, "environments")
        XCTAssertTrue(CachedClient.matches(pattern: "environments", path: path))
    }

    func testMergeDeduplicatesAppendedPagesAndResetReplacesExistingRows() {
        let current = [TestResource(id: 1), TestResource(id: 2)]
        let incoming = [TestResource(id: 2), TestResource(id: 3)]

        XCTAssertEqual(
            PaginationLoader.merge(current: current, incoming: incoming, reset: false).map(\.id),
            [1, 2, 3]
        )
        XCTAssertEqual(
            PaginationLoader.merge(current: current, incoming: incoming, reset: true).map(\.id),
            [2, 3]
        )
    }

    func testProgressiveStateUsesServerStrideAndRejectsStaleRefreshes() {
        var state = ProgressivePaginationState()
        let firstGeneration = state.reset()
        XCTAssertTrue(state.receive(
            pagination: pagination(totalPages: 6, totalItems: 101, currentPage: 1, itemsPerPage: 20),
            itemCount: 20,
            requestedStart: 0,
            requestedLimit: 50,
            generation: firstGeneration
        ))
        XCTAssertEqual(state.nextStart, 20)
        XCTAssertTrue(state.hasMore)
        XCTAssertEqual(state.totalItems, 101)

        let refreshedGeneration = state.reset()
        XCTAssertFalse(state.receive(
            pagination: pagination(totalPages: 6, totalItems: 101, currentPage: 2, itemsPerPage: 20),
            itemCount: 20,
            requestedStart: 20,
            requestedLimit: 50,
            generation: firstGeneration
        ))
        XCTAssertEqual(state.nextStart, 0)
        XCTAssertFalse(state.hasMore)
        XCTAssertNil(state.totalItems)
        XCTAssertTrue(state.accepts(refreshedGeneration))
    }

    func testProgressiveStateRetainsKnownTotalWhenLaterPageOmitsIt() {
        var state = ProgressivePaginationState()
        let generation = state.reset()
        XCTAssertTrue(state.receive(
            pagination: pagination(totalPages: 3, totalItems: 101, currentPage: 1, itemsPerPage: 50),
            itemCount: 50,
            requestedStart: 0,
            requestedLimit: 50,
            generation: generation
        ))
        XCTAssertTrue(state.receive(
            pagination: pagination(totalPages: -1, totalItems: -1, currentPage: 2, itemsPerPage: 50),
            itemCount: 50,
            requestedStart: 50,
            requestedLimit: 50,
            generation: generation
        ))

        XCTAssertEqual(state.totalItems, 101)
    }

    func testProgressiveStateKeepsFailedPageCursorForRetry() {
        var state = ProgressivePaginationState()
        let generation = state.reset()
        XCTAssertTrue(state.receive(
            pagination: pagination(totalPages: 2, totalItems: 75, currentPage: 1, itemsPerPage: 50),
            itemCount: 50,
            requestedStart: 0,
            requestedLimit: 50,
            generation: generation
        ))

        let retryStart = state.nextStart
        XCTAssertEqual(retryStart, 50)
        XCTAssertTrue(state.hasMore)

        XCTAssertTrue(state.receive(
            pagination: pagination(totalPages: 2, totalItems: 75, currentPage: 2, itemsPerPage: 50),
            itemCount: 25,
            requestedStart: retryStart,
            requestedLimit: 50,
            generation: generation
        ))
        XCTAssertEqual(state.nextStart, 100)
        XCTAssertFalse(state.hasMore)
    }

    func testCollectPropagatesLaterPageFailureInsteadOfCachingPartialResults() async {
        do {
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
            XCTFail("Expected the later page error to be propagated")
        } catch TestPaginationError.failedPage {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCollectRejectsServerTotalAboveSafetyLimit() async {
        do {
            _ = try await PaginationLoader.collect(pageSize: 2, maximumItems: 2) { _, _ in
                ResourcePage(
                    items: [TestResource(id: 1), TestResource(id: 2)],
                    pagination: .init(totalPages: 2, totalItems: 3, currentPage: 1, itemsPerPage: 2)
                )
            }
            XCTFail("Expected the collection limit to be enforced")
        } catch RemoteDataLimitError.collectionTooLarge(let maximumItems) {
            XCTAssertEqual(maximumItems, 2)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCollectRejectsUnknownTotalWhenUniqueItemsExceedLimit() async {
        do {
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
            XCTFail("Expected the collection limit to be enforced")
        } catch RemoteDataLimitError.collectionTooLarge(let maximumItems) {
            XCTAssertEqual(maximumItems, 2)
        } catch {
            XCTFail("Unexpected error: \(error)")
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

nonisolated private struct TestResource: Identifiable, Sendable {
    let id: Int
}

nonisolated private enum TestPaginationError: Error {
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
