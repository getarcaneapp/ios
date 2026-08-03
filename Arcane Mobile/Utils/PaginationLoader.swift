import Arcane
import Foundation

nonisolated struct ResourcePage<Element: Sendable>: Sendable {
    let items: [Element]
    let pagination: PaginationResponse
}

nonisolated enum PaginationLoader {
    static let defaultPageSize = 50

    static func collect<Element: Identifiable & Sendable>(
        pageSize: Int = defaultPageSize,
        maximumItems: Int = RemoteDataLimits.maximumCollectionItems,
        fetchPage: @Sendable (_ start: Int, _ limit: Int) async throws -> ResourcePage<Element>
    ) async throws -> [Element] where Element.ID: Sendable {
        let limit = max(1, pageSize)
        let itemLimit = max(1, maximumItems)
        var start = 0
        var collected: [Element] = []
        var seen = Set<Element.ID>()

        while true {
            let page = try await fetchPage(start, limit)
            if page.pagination.totalItems > Int64(itemLimit) {
                throw RemoteDataLimitError.collectionTooLarge(maximumItems: itemLimit)
            }
            for item in page.items where seen.insert(item.id).inserted {
                guard collected.count < itemLimit else {
                    throw RemoteDataLimitError.collectionTooLarge(maximumItems: itemLimit)
                }
                collected.append(item)
            }

            let pageStride = page.pagination.itemsPerPage > 0
                ? page.pagination.itemsPerPage
                : limit
            let (nextStart, offsetOverflow) = start.addingReportingOverflow(pageStride)
            guard !offsetOverflow, nextStart > start else {
                throw RemoteDataLimitError.collectionTooLarge(maximumItems: itemLimit)
            }
            let reachedEnd: Bool
            if page.pagination.totalItems >= 0 {
                reachedEnd = Int64(nextStart) >= page.pagination.totalItems
            } else if page.pagination.totalPages >= 0 {
                reachedEnd = Int64(page.pagination.currentPage) >= page.pagination.totalPages
            } else {
                reachedEnd = page.items.count < pageStride
            }

            guard !page.items.isEmpty, !reachedEnd else {
                return collected
            }
            start = nextStart
        }
    }

    static func cachePath(for path: String) -> String {
        path + "#all-pages"
    }

    static func merge<Element: Identifiable>(
        current: [Element],
        incoming: [Element],
        reset: Bool
    ) -> [Element] {
        var merged: [Element] = []
        var seen = Set<Element.ID>()
        let source = reset ? incoming : current + incoming
        for item in source where seen.insert(item.id).inserted {
            merged.append(item)
        }
        return merged
    }
}

nonisolated struct ProgressivePaginationState: Sendable {
    private(set) var generation = 0
    private(set) var nextStart = 0
    private(set) var hasMore = false
    private(set) var totalItems: Int64?

    mutating func reset() -> Int {
        generation += 1
        nextStart = 0
        hasMore = false
        totalItems = nil
        return generation
    }

    func accepts(_ requestGeneration: Int) -> Bool {
        generation == requestGeneration
    }

    @discardableResult
    mutating func receive(
        pagination: PaginationResponse,
        itemCount: Int,
        requestedStart: Int,
        requestedLimit: Int,
        generation requestGeneration: Int
    ) -> Bool {
        guard accepts(requestGeneration) else { return false }

        if pagination.totalItems >= 0 {
            totalItems = pagination.totalItems
        }

        let pageStride = pagination.itemsPerPage > 0
            ? pagination.itemsPerPage
            : max(1, requestedLimit)
        let (candidateStart, offsetOverflow) = requestedStart.addingReportingOverflow(pageStride)
        guard !offsetOverflow, candidateStart > requestedStart else {
            hasMore = false
            return true
        }
        nextStart = candidateStart

        guard itemCount > 0 else {
            hasMore = false
            return true
        }

        if pagination.totalItems >= 0 {
            hasMore = Int64(candidateStart) < pagination.totalItems
        } else if pagination.totalPages >= 0 {
            hasMore = Int64(pagination.currentPage) < pagination.totalPages
        } else {
            hasMore = itemCount >= pageStride
        }
        return true
    }
}
