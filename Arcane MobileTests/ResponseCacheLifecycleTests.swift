import Foundation
import Testing

@testable import Arcane_Mobile

@Suite("Response cache lifecycle")
struct ResponseCacheLifecycleTests {
    @Test
    func invalidationRejectsDelayedWritesAndReplacementFetchDoesNotJoinOldRequest() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ResponseCache(directory: directory)
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
        #expect(await cache.get(key, as: String.self, ttl: 60) == "new")
    }

    @Test
    func invalidationRetiresBackgroundCallbackLease() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ResponseCache(directory: directory)
        let key = key()
        let generation = await cache.generation(for: key)
        let gate = CacheLifecycleGate()
        let fetch = Task {
            try await cache.coalesce(key, generation: generation) {
                await gate.wait()
                return "late callback"
            }
        }
        await gate.waitUntilStarted()
        await cache.invalidateAll()
        #expect(!generation.isValid)
        await gate.release()
        await #expect(throws: CancellationError.self) { try await fetch.value }
        #expect(await cache.get(key, as: String.self, ttl: 60) == nil)
    }

    @Test
    func invalidationRetiresPendingDiskReads() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = key()
        let writer = ResponseCache(directory: directory)
        await writer.set(key, value: "disk value")
        let queue = DispatchQueue(label: "cache-lifecycle-test")
        let reader = ResponseCache(directory: directory, ioQueue: queue)
        let generation = await reader.generation(for: key)
        queue.suspend()
        let read = Task {
            await reader.getEntry(key, as: String.self, ttl: 60, generation: generation)
        }
        let invalidation = Task { await reader.invalidateAll() }
        while generation.isValid { await Task.yield() }
        queue.resume()
        await invalidation.value
        #expect(await read.value == nil)
        #expect(await reader.get(key, as: String.self, ttl: 60) == nil)
    }

    private func key() -> CacheKey {
        CacheKey(serverIdentity: "https://cache.test:443", userID: "one", sessionIdentity: UUID().uuidString,
                 envID: "one", pathWithQuery: "containers")
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
