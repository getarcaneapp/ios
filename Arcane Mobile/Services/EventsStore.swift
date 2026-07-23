import Foundation
import Observation
import Arcane

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
    private(set) var errorMessage: String?

    var searchText = ""
    var selectedSeverities: Set<EventSeverityFilter> = []

    private var client: ArcaneClient?
    private var clientTransportIdentity: ObjectIdentifier?

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
        events = []
        severityCounts = nil
        supportsSeverityCounts = true
        deletingEventIDs = []
        hasMore = false
        errorMessage = nil
    }

    func reload(clearExisting: Bool = false) async {
        guard let client else { return }
        let requestedQuery = queryKey
        if clearExisting { events = [] }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

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
            guard requestedQuery == queryKey else { return }
            events = response.data
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
            let response = try await client.events.listPaginated(
                search: normalizedSearch,
                sort: "timestamp",
                order: .descending,
                start: events.count,
                limit: Self.pageSize,
                severity: encodedSeverities
            )
            try Task.checkCancellation()
            guard requestedQuery == queryKey else { return }

            let existingIDs = Set(events.map(\.id))
            events.append(contentsOf: response.data.filter { !existingIDs.contains($0.id) })
            hasMore = Int64(events.count) < response.pagination.totalItems
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard requestedQuery == queryKey else { return }
            errorMessage = friendlyErrorMessage(error)
        }
    }

    func loadSeverityCounts() async {
        guard supportsSeverityCounts, let client else { return }
        do {
            severityCounts = try await client.events.stats()
        } catch ArcaneError.notFound {
            supportsSeverityCounts = false
            severityCounts = nil
        } catch {
            // Summary counts are supplemental; the event list remains usable.
        }
    }

    func poll() async {
        guard let client, !isLoading, !isLoadingMore else { return }
        let requestedQuery = queryKey
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
            guard requestedQuery == queryKey, !isLoading, !isLoadingMore else { return }
            events = EventHistory.merged(
                current: events,
                incoming: response.data,
                limit: max(Self.pageSize, events.count)
            )
            hasMore = Int64(events.count) < response.pagination.totalItems
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
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
