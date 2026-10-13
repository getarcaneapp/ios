import Arcane
import Foundation

nonisolated struct ResourcePage<Element: Sendable>: Sendable {
    let items: [Element]
    let pagination: PaginationResponse
}

nonisolated enum PaginationLoader {
    static let defaultPageSize = 50

    /// Collects every page. The first page reports the total, so the
    /// remaining pages are requested concurrently and merged in order.
    static func collect<Element: Identifiable & Sendable>(
        pageSize: Int = defaultPageSize,
        maximumItems: Int = RemoteDataLimits.maximumCollectionItems,
        fetchPage: @escaping @Sendable (_ start: Int, _ limit: Int) async throws -> ResourcePage<Element>
    ) async throws -> [Element] where Element.ID: Sendable {
        let limit = max(1, pageSize)
        let itemLimit = max(1, maximumItems)
        var start = 0
        var collected: [Element] = []
        var seen = Set<Element.ID>()

        func append(_ page: ResourcePage<Element>) throws {
            if page.pagination.totalItems > Int64(itemLimit) {
                throw RemoteDataLimitError.collectionTooLarge(maximumItems: itemLimit)
            }
            for item in page.items where seen.insert(item.id).inserted {
                guard collected.count < itemLimit else {
                    throw RemoteDataLimitError.collectionTooLarge(maximumItems: itemLimit)
                }
                collected.append(item)
            }
        }

        /// The next page's offset, or nil once `page` is the last one.
        func next(after page: ResourcePage<Element>, at start: Int) throws -> (start: Int, stride: Int)? {
            let pageStride =
                page.pagination.itemsPerPage > 0
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
            guard !page.items.isEmpty, !reachedEnd else { return nil }
            return (nextStart, pageStride)
        }

        var usedKnownTotal = false
        while true {
            let page = try await fetchPage(start, limit)
            try append(page)
            guard let following = try next(after: page, at: start) else { return collected }

            // A known total lets every remaining page load at once. Pages are
            // merged in offset order, so the result matches a sequential walk.
            guard !usedKnownTotal, page.pagination.totalItems >= 0 else {
                start = following.start
                continue
            }
            usedKnownTotal = true
            let total = Int(min(page.pagination.totalItems, Int64(itemLimit)))
            let starts = Array(stride(from: following.start, to: total, by: following.stride))
            guard starts.count > 1 else {
                start = following.start
                continue
            }
            let pages = try await withThrowingTaskGroup(of: (Int, ResourcePage<Element>).self) { group in
                for (index, pageStart) in starts.enumerated() {
                    group.addTask { (index, try await fetchPage(pageStart, limit)) }
                }
                var ordered = [ResourcePage<Element>?](repeating: nil, count: starts.count)
                for try await (index, page) in group { ordered[index] = page }
                return ordered.compactMap { $0 }
            }
            for page in pages { try append(page) }
            // The collection can grow while the pages load; keep walking
            // from the last page if it isn't the end anymore.
            guard let lastStart = starts.last, let lastPage = pages.last,
                let after = try next(after: lastPage, at: lastStart)
            else { return collected }
            start = after.start
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

        let pageStride =
            pagination.itemsPerPage > 0
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
