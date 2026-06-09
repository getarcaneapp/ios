import Foundation

/// Bounds how much an async stream (logs, stats) can contribute to a tool's
/// output. Runs a collector closure racing a timeout and returns whatever the
/// collector accumulated by the time either finishes — so a chatty container
/// can't blow the small context window, and an idle/slow one can't hang the
/// model's generation loop.
@available(iOS 26, *)
enum StreamBudget {
    /// Thread-safe accumulator shared by the collector and the timeout racer.
    actor Box {
        private(set) var items: [String] = []
        func append(_ s: String) { items.append(s) }
        func all() -> [String] { items }
    }

    static func bounded(
        timeout: Duration = .seconds(3),
        _ collect: @escaping @Sendable (Box) async -> Void
    ) async -> [String] {
        let box = Box()
        return await withTaskGroup(of: Void.self) { group in
            group.addTask { await collect(box) }
            group.addTask { try? await Task.sleep(for: timeout) }
            await group.next()        // first to finish: collector done OR timeout
            group.cancelAll()
            return await box.all()
        }
    }
}
