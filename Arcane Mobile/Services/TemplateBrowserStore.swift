import Foundation
import Observation
import Arcane

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
    private(set) var errorMessage: String?

    var searchText = ""
    var source: TemplateSourceSelection = .all

    private var client: ArcaneClient?
    private var clientTransportIdentity: ObjectIdentifier?

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
        templates = []
        hasMore = false
        errorMessage = nil
    }

    func reload(clearExisting: Bool = false) async {
        guard let client else { return }
        let requestedQuery = queryKey
        if clearExisting { templates = [] }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

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
            guard requestedQuery == queryKey else { return }
            templates = response.data
            hasMore = Int64(response.data.count) < response.pagination.totalItems
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard requestedQuery == queryKey else { return }
            errorMessage = friendlyErrorMessage(error)
        }
    }

    func loadMore() async {
        guard let client, hasMore, !isLoadingMore else { return }
        let requestedQuery = queryKey
        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let response = try await client.templates.listPaginated(
                search: normalizedSearch,
                sort: "name",
                order: .ascending,
                start: templates.count,
                limit: Self.pageSize,
                source: source.sdkFilter
            )
            try Task.checkCancellation()
            guard requestedQuery == queryKey else { return }

            let existingIDs = Set(templates.map(\.id))
            templates.append(contentsOf: response.data.filter { !existingIDs.contains($0.id) })
            hasMore = Int64(templates.count) < response.pagination.totalItems
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard requestedQuery == queryKey else { return }
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private var normalizedSearch: String? {
        let value = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
