import Foundation

/// Runs one request per input concurrently, with no cap, and hands results to
/// `deliver` as they arrive instead of after the slowest one. Results that land
/// within `interval` of the previous delivery are coalesced into one batch, so
/// many fast environments publish in a few UI updates while one slow or offline
/// environment never holds the others back.
enum ProgressiveFanOut {
    static func run<Input: Sendable, Output: Sendable>(
        _ inputs: [Input],
        interval: Duration = .milliseconds(100),
        work: @escaping @Sendable (Input) async -> Output,
        deliver: ([Output]) -> Void
    ) async {
        guard !inputs.isEmpty else { return }
        await withTaskGroup(of: FanOutEvent<Output>.self) { group in
            for input in inputs {
                group.addTask { .output(await work(input)) }
            }
            var remaining = inputs.count
            var pending: [Output] = []
            var lastDelivery: ContinuousClock.Instant?
            var tickScheduled = false
            while remaining > 0, let event = await group.next() {
                switch event {
                case .output(let output):
                    remaining -= 1
                    pending.append(output)
                case .tick:
                    tickScheduled = false
                }
                guard !pending.isEmpty, remaining > 0 else { continue }
                let now = ContinuousClock.now
                if let lastDelivery, now - lastDelivery < interval {
                    guard !tickScheduled else { continue }
                    tickScheduled = true
                    let delay = interval - (now - lastDelivery)
                    group.addTask {
                        try? await Task.sleep(for: delay)
                        return .tick
                    }
                } else {
                    deliver(pending)
                    pending.removeAll()
                    lastDelivery = now
                }
            }
            group.cancelAll()
            if !pending.isEmpty { deliver(pending) }
        }
    }
}

private nonisolated enum FanOutEvent<Output: Sendable>: Sendable {
    case output(Output)
    case tick
}
