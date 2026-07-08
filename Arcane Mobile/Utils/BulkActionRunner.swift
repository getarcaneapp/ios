import Foundation

struct BulkResult {
    let succeeded: Int
    let failed: [(id: String, error: Error)]
}

enum BulkActionRunner {
    static func run(
        ids: [String],
        operation: (String) async throws -> Void
    ) async -> BulkResult {
        var succeeded = 0
        var failed: [(id: String, error: Error)] = []

        for id in ids {
            do {
                try await operation(id)
                succeeded += 1
            } catch {
                failed.append((id: id, error: error))
            }
        }

        return BulkResult(succeeded: succeeded, failed: failed)
    }
}
