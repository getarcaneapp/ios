import Arcane
import Observation

@MainActor @Observable
final class FleetOperationStore {
    private(set) var results: [FleetOperationResult] = []
    private(set) var isRunning = false

    func run(environments: [Arcane.Environment], isCurrent: () -> Bool,
             operation: (EnvironmentID) async throws -> String) async {
        guard !isRunning, results.isEmpty else { return }
        results = environments.filter(\.enabled).map { .init(id: $0.id, name: $0.displayName) }
        isRunning = true
        defer { isRunning = false }
        for index in results.indices {
            guard !Task.isCancelled, isCurrent() else {
                for remaining in index..<results.count {
                    results[remaining].status = "Not started: connection changed or operation cancelled"
                    results[remaining].failed = true
                    results[remaining].finished = true
                }
                return
            }
            results[index].status = "Running…"
            do {
                results[index].status = try await operation(EnvironmentID(rawValue: results[index].id))
            } catch {
                results[index].status = friendlyErrorMessage(error)
                results[index].failed = true
            }
            results[index].finished = true
        }
    }
}
