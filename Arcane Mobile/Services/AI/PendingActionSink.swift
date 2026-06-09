import Foundation

/// Actor-backed, `Sendable` queue that mutation tools register staged actions
/// into from their off-actor `call()`. The service drains it once per turn (on
/// the MainActor) — a single deterministic reconciliation point that avoids
/// racing the streaming snapshot updates.
actor AIPendingActionSink {
    private var staged: [AIPendingAction] = []

    func register(_ action: AIPendingAction) {
        staged.append(action)
    }

    /// Returns everything staged since the last drain and clears the queue.
    func drain() -> [AIPendingAction] {
        let snapshot = staged
        staged.removeAll()
        return snapshot
    }
}
