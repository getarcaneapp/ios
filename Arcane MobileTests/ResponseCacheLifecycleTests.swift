import Foundation
import Testing

@testable import Arcane_Mobile

@Suite("Response cache lifecycle")
struct ResponseCacheLifecycleTests {
    @Test
    func concurrentCallersShareOneRequest() async throws {
        let cache = ResponseCache()
        let key = key()
        let counter = FetchCounter()
        let gate = CacheLifecycleGate()
        let first = Task {
            try await cache.coalesce(key) {
                _ = await counter.increment()
                await gate.wait()
                return "shared"
            }
        }
        await gate.waitUntilStarted()
        let second = Task { try await cache.coalesce(key) { _ = await counter.increment(); return "second" } }
        // Let the second caller reach the cache while the first is in flight.
        try await Task.sleep(for: .milliseconds(100))
        await gate.release()
        #expect(try await first.value == "shared")
        #expect(try await second.value == "shared")
        #expect(await counter.value == 1)
    }

    @Test
    func sequentialCallsAlwaysFetchFresh() async throws {
        let cache = ResponseCache()
        let key = key()
        let counter = FetchCounter()
        let first = try await cache.coalesce(key) { await counter.increment() }
        let second = try await cache.coalesce(key) { await counter.increment() }
        #expect(first == 1)
        #expect(second == 2)
    }

    @Test
    func invalidationCancelsAndReplacementFetchDoesNotJoinOldRequest() async throws {
        let cache = ResponseCache()
        let key = key()
        let oldGate = CacheLifecycleGate()
        let old = Task {
            try await cache.coalesce(key) {
                await oldGate.wait()
                return "old"
            }
        }
        await oldGate.waitUntilStarted()
        await cache.invalidateEnvironment(key.envID)

        let newGate = CacheLifecycleGate()
        let new = Task {
            try await cache.coalesce(key) {
                await newGate.wait()
                return "new"
            }
        }
        await newGate.waitUntilStarted()
        await oldGate.release()
        await #expect(throws: CancellationError.self) { try await old.value }
        await newGate.release()
        #expect(try await new.value == "new")
    }

    @Test
    func invalidationRetiresInFlightLease() async throws {
        let cache = ResponseCache()
        let key = key()
        let gate = CacheLifecycleGate()
        let fetch = Task {
            try await cache.coalesce(key) {
                await gate.wait()
                return "late callback"
            }
        }
        await gate.waitUntilStarted()
        let generation = await cache.generation(for: key)
        await cache.invalidateAll()
        #expect(!generation.isValid)
        await gate.release()
        await #expect(throws: CancellationError.self) { try await fetch.value }
    }

    private func key() -> CacheKey {
        CacheKey(
            serverIdentity: "https://cache.test:443", userID: "one", sessionIdentity: UUID().uuidString,
            envID: "one", pathWithQuery: "containers")
    }
}

@Suite("Progressive fan-out")
@MainActor
struct ProgressiveFanOutTests {
    @Test
    func deliversEveryResultWithoutWaitingForTheSlowest() async {
        let slowGate = CacheLifecycleGate()
        let delivered = DeliveredBatches()
        let run = Task { @MainActor in
            await ProgressiveFanOut.run([1, 2, 3], interval: .zero) { value in
                if value == 3 { await slowGate.wait() }
                return value
            } deliver: { batch in
                delivered.values += batch
            }
        }
        // The fast results publish while the slow one is still pending.
        while delivered.values.count < 2 { await Task.yield() }
        #expect(Set(delivered.values) == [1, 2])
        await slowGate.release()
        await run.value
        #expect(delivered.values.sorted() == [1, 2, 3])
    }

    @Test
    func coalescesResultsWithinTheInterval() async {
        var batches: [[Int]] = []
        await ProgressiveFanOut.run(Array(0..<20), interval: .seconds(10)) { value in
            value
        } deliver: { batch in
            batches.append(batch)
        }
        // The first result publishes immediately; the rest arrive within the
        // interval and land together at the end.
        #expect(batches.count <= 2)
        #expect(batches.flatMap { $0 }.sorted() == Array(0..<20))
    }
}

@MainActor
private final class DeliveredBatches {
    var values: [Int] = []
}

private actor FetchCounter {
    private(set) var value = 0

    func increment() -> Int {
        value += 1
        return value
    }
}

private actor CacheLifecycleGate {
    private var started = false
    private var released = false
    private var waitingForStart: [CheckedContinuation<Void, Never>] = []
    private var waitingForRelease: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        started = true
        waitingForStart.forEach { $0.resume() }
        waitingForStart = []
        if released { return }
        await withCheckedContinuation { waitingForRelease.append($0) }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { waitingForStart.append($0) }
    }

    func release() {
        released = true
        waitingForRelease.forEach { $0.resume() }
        waitingForRelease = []
    }
}
