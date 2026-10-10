import Arcane
import Foundation
import Observation

nonisolated enum TemplateSourceSelection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case all
    case local
    case remote

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .local: "Local"
        case .remote: "Remote"
        }
    }

    var icon: String {
        switch self {
        case .all: "square.grid.2x2"
        case .local: "internaldrive"
        case .remote: "cloud"
        }
    }

    var sdkFilter: TemplateSourceFilter {
        switch self {
        case .all: .all
        case .local: .local
        case .remote: .remote
        }
    }
}

@MainActor
@Observable
final class TemplateBrowserStore {
    private static let pageSize = 30

    private(set) var templates: [Template] = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var hasMore = false
    private(set) var totalItemCount: Int64?
    private(set) var errorMessage: String?
    private(set) var loadMoreError: String?

    var searchText = ""
    var source: TemplateSourceSelection = .all

    private var client: ArcaneClient?
    private var clientTransportIdentity: ObjectIdentifier?
    private var pagination = ProgressivePaginationState()

    var queryKey: String {
        "\(searchText.trimmingCharacters(in: .whitespacesAndNewlines))|\(source.rawValue)"
    }

    func configure(client: ArcaneClient?) {
        let nextIdentity = client.map { ObjectIdentifier($0.transport) }
        guard nextIdentity != clientTransportIdentity else {
            self.client = client
            return
        }

        self.client = client
        clientTransportIdentity = nextIdentity
        _ = pagination.reset()
        isLoading = false
        isLoadingMore = false
        templates = []
        hasMore = false
        totalItemCount = nil
        errorMessage = nil
        loadMoreError = nil
    }

    func reload(clearExisting: Bool = false) async {
        guard let client else { return }
        let requestedQuery = queryKey
        let generation = pagination.reset()
        isLoadingMore = false
        hasMore = false
        totalItemCount = nil
        if clearExisting { templates = [] }
        isLoading = true
        errorMessage = nil
        loadMoreError = nil
        defer { if pagination.accepts(generation) { isLoading = false } }

        do {
            let response = try await client.templates.listPaginated(
                search: normalizedSearch,
                sort: "name",
                order: .ascending,
                start: 0,
                limit: Self.pageSize,
                source: source.sdkFilter
            )
            try Task.checkCancellation()
            guard pagination.accepts(generation), requestedQuery == queryKey else { return }
            templates = PaginationLoader.merge(current: [], incoming: response.data, reset: true)
            pagination.receive(
                pagination: response.pagination, itemCount: response.data.count,
                requestedStart: 0, requestedLimit: Self.pageSize, generation: generation
            )
            hasMore = pagination.hasMore
            totalItemCount = pagination.totalItems
            errorMessage = nil
            loadMoreError = nil
        } catch is CancellationError {
            return
        } catch {
            guard pagination.accepts(generation), requestedQuery == queryKey else { return }
            errorMessage = friendlyErrorMessage(error)
        }
    }

    func loadMore() async {
        guard let client, hasMore, !isLoading, !isLoadingMore else { return }
        let requestedQuery = queryKey
        let generation = pagination.generation
        let start = pagination.nextStart
        loadMoreError = nil
        isLoadingMore = true
        defer { if pagination.accepts(generation) { isLoadingMore = false } }

        do {
            let response = try await client.templates.listPaginated(
                search: normalizedSearch,
                sort: "name",
                order: .ascending,
                start: start,
                limit: Self.pageSize,
                source: source.sdkFilter
            )
            try Task.checkCancellation()
            guard pagination.accepts(generation), requestedQuery == queryKey else { return }

            templates = PaginationLoader.merge(current: templates, incoming: response.data, reset: false)
            pagination.receive(
                pagination: response.pagination, itemCount: response.data.count,
                requestedStart: start, requestedLimit: Self.pageSize, generation: generation
            )
            hasMore = pagination.hasMore
            totalItemCount = pagination.totalItems
            loadMoreError = nil
        } catch is CancellationError {
            return
        } catch {
            guard pagination.accepts(generation), requestedQuery == queryKey else { return }
            loadMoreError = friendlyErrorMessage(error)
        }
    }

    private var normalizedSearch: String? {
        let value = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
