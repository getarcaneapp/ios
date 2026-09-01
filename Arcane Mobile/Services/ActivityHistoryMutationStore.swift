import Observation

@MainActor
@Observable
final class ActivityHistoryMutationStore {
    struct ClearEvent: Equatable, Sendable {
        let sequence: Int
        let environmentIDs: Set<String>
    }

    static let shared = ActivityHistoryMutationStore()

    private(set) var latestClear: ClearEvent?
    private var sequence = 0

    init() {}

    func recordClear(environmentIDs: Set<String>) {
        guard !environmentIDs.isEmpty else { return }
        sequence &+= 1
        latestClear = ClearEvent(sequence: sequence, environmentIDs: environmentIDs)
    }
}
