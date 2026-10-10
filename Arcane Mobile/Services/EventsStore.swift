import Arcane
import Foundation
import Observation

nonisolated enum EventSeverityFilter: String, CaseIterable, Identifiable, Hashable, Sendable {
    case info
    case success
    case warning
    case error

    var id: String { rawValue }

    var title: String {
        switch self {
        case .info: "Info"
        case .success: "Success"
        case .warning: "Warning"
        case .error: "Error"
        }
    }

    var icon: String {
        switch self {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }
}

@MainActor
@Observable
final class EventsStore {
    private static let pageSize = 50

    private(set) var events: [Event] = []
    private(set) var severityCounts: EventSeverityCounts?
    private(set) var supportsSeverityCounts = true
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var deletingEventIDs: Set<String> = []
    private(set) var hasMore = false
    private(set) var totalItemCount: Int64?
    private(set) var errorMessage: String?
    private(set) var loadMoreError: String?

    var searchText = ""
    var selectedSeverities: Set<EventSeverityFilter> = []

    private var client: ArcaneClient?
    private var clientTransportIdentity: ObjectIdentifier?
    private var pagination = ProgressivePaginationState()

    var queryKey: String {
        let severities = selectedSeverities.map(\.rawValue).sorted().joined(separator: ",")
        return "\(searchText.trimmingCharacters(in: .whitespacesAndNewlines))|\(severities)"
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
        events = []
        severityCounts = nil
        supportsSeverityCounts = true
        deletingEventIDs = []
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
        if clearExisting { events = [] }
        isLoading = true
        errorMessage = nil
        loadMoreError = nil
        defer { if pagination.accepts(generation) { isLoading = false } }

        do {
            let response = try await client.events.listPaginated(
                search: normalizedSearch,
                sort: "timestamp",
                order: .descending,
                start: 0,
                limit: Self.pageSize,
                severity: encodedSeverities
            )
            try Task.checkCancellation()
            guard pagination.accepts(generation), requestedQuery == queryKey else { return }
            events = PaginationLoader.merge(current: [], incoming: response.data, reset: true)
            pagination.receive(
                pagination: response.pagination, itemCount: response.data.count,
                requestedStart: 0, requestedLimit: Self.pageSize, generation: generation
            )
            hasMore = pagination.hasMore
            totalItemCount = pagination.totalItems
            errorMessage = nil
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
        isLoadingMore = true
        loadMoreError = nil
        defer { if pagination.accepts(generation) { isLoadingMore = false } }

        do {
            let response = try await client.events.listPaginated(
                search: normalizedSearch,
                sort: "timestamp",
                order: .descending,
                start: start,
                limit: Self.pageSize,
                severity: encodedSeverities
            )
            try Task.checkCancellation()
            guard pagination.accepts(generation), requestedQuery == queryKey else { return }

            events = PaginationLoader.merge(current: events, incoming: response.data, reset: false)
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

    func loadSeverityCounts() async {
        guard supportsSeverityCounts, let client else { return }
        let identity = clientTransportIdentity
        do {
            let counts = try await client.events.stats()
            guard identity == clientTransportIdentity else { return }
            severityCounts = counts
        } catch ArcaneError.notFound {
            guard identity == clientTransportIdentity else { return }
            supportsSeverityCounts = false
            severityCounts = nil
        } catch {
            // Summary counts are supplemental; the event list remains usable.
        }
    }

    func poll() async {
        guard let client, !isLoading, !isLoadingMore else { return }
        let requestedQuery = queryKey
        let generation = pagination.generation
        do {
            let response = try await client.events.listPaginated(
                search: normalizedSearch,
                sort: "timestamp",
                order: .descending,
                start: 0,
                limit: Self.pageSize,
                severity: encodedSeverities
            )
            try Task.checkCancellation()
            guard pagination.accepts(generation), requestedQuery == queryKey, !isLoading, !isLoadingMore else { return }
            events = EventHistory.merged(
                current: events,
                incoming: response.data,
                limit: max(Self.pageSize, events.count)
            )
            if response.pagination.totalItems >= 0 {
                hasMore = Int64(pagination.nextStart) < response.pagination.totalItems
                totalItemCount = response.pagination.totalItems
            }
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard pagination.accepts(generation), requestedQuery == queryKey else { return }
            if events.isEmpty { errorMessage = friendlyErrorMessage(error) }
        }
    }

    func delete(_ event: Event) async throws {
        guard let client else { return }
        deletingEventIDs.insert(event.id)
        defer { deletingEventIDs.remove(event.id) }

        try await client.events.delete(id: event.id)
        events.removeAll { $0.id == event.id }
        await loadSeverityCounts()
    }

    func toggle(_ severity: EventSeverityFilter) {
        if selectedSeverities.contains(severity) {
            selectedSeverities.remove(severity)
        } else {
            selectedSeverities.insert(severity)
        }
    }

    func clearSeverities() {
        selectedSeverities.removeAll()
    }

    private var normalizedSearch: String? {
        let value = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private var encodedSeverities: String? {
        let value = selectedSeverities.map(\.rawValue).sorted().joined(separator: ",")
        return value.isEmpty ? nil : value
    }
}
