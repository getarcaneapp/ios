import Foundation
import Synchronization

// In-flight request deduplication for API GET responses. Concurrent callers
// for the same key share one network request; every call that starts after
// the previous one finished gets a fresh response. Nothing is stored after a
// request completes, so a stale value can never be served.
//
// Note: the project defaults to SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor,
// so every type/extension here is explicitly `nonisolated` to avoid
// implicit @MainActor inference on Sendable/Hashable conformances.

nonisolated struct CacheKey: Hashable, Sendable {
    let serverIdentity: String  // canonical scheme + host + effective port + base path
    let userID: String  // currentUser?.id ?? "anon" (multi-account safety)
    let sessionIdentity: String  // rotates for every authenticated session
    let envID: String  // active environment raw value
    let pathWithQuery: String
}

nonisolated enum ResponseCacheError: Error {
    case typeMismatch
}

actor ResponseCache {
    static let shared = ResponseCache(removesLegacyDiskCache: true)

    private struct InFlight {
        let id: UUID
        let generation: CacheGeneration
        let task: Task<any Sendable, Error>
    }
    private var inFlight: [CacheKey: InFlight] = [:]

    init(removesLegacyDiskCache: Bool = false) {
        guard removesLegacyDiskCache else { return }
        // Earlier builds persisted responses to disk. Remove them once.
        Task.detached(priority: .background) {
            let fm = FileManager.default
            guard let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
            for name in ["ResponseCache", "ResponseCache-v2", "ResponseCache-v3"] {
                try? fm.removeItem(at: caches.appendingPathComponent(name, isDirectory: true))
            }
        }
    }

    // MARK: - Invalidation

    /// The lease of the request currently in flight for `key`, or a new one.
    func generation(for key: CacheKey) -> CacheGeneration {
        inFlight[key]?.generation ?? CacheGeneration()
    }

    /// Cancels matching in-flight requests so the next caller starts a fresh
    /// one instead of joining a request that predates a mutation.
    func invalidate(matching predicate: @Sendable (CacheKey) -> Bool) {
        for key in Array(inFlight.keys) where predicate(key) {
            guard let request = inFlight.removeValue(forKey: key) else { continue }
            request.generation.invalidate()
            request.task.cancel()
        }
    }

    func invalidateEnvironment(_ envID: String) {
        invalidate(matching: { $0.envID == envID })
    }

    func invalidateAll() {
        invalidate(matching: { _ in true })
    }

    // MARK: - Dedup

    func coalesce<T: Sendable>(
        _ key: CacheKey,
        generation: CacheGeneration? = nil,
        work: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        let request: InFlight
        if let existing = inFlight[key], generation == nil || existing.generation === generation {
            request = existing
        } else {
            let generation = generation ?? CacheGeneration()
            guard generation.isValid else { throw CancellationError() }
            request = InFlight(
                id: UUID(), generation: generation,
                task: Task { try await work() as any Sendable }
            )
            inFlight[key] = request
        }
        defer {
            if inFlight[key]?.id == request.id { inFlight.removeValue(forKey: key) }
        }
        let any = try await request.task.value
        try Task.checkCancellation()
        guard request.generation.isValid else { throw CancellationError() }
        guard let typed = any as? T else { throw ResponseCacheError.typeMismatch }
        return typed
    }
}

/// A shared validity lease also lets MainActor callbacks check freshness without
/// suspending between the check and applying the result.
nonisolated final class CacheGeneration: Sendable {
    private let valid = Mutex(true)

    var isValid: Bool {
        valid.withLock { $0 }
    }

    func invalidate() {
        valid.withLock { $0 = false }
    }
}
