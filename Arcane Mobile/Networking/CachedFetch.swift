import Foundation
import Arcane

// Stale-while-revalidate wrapper around `client.rest.get`. Views call this
// to get a cached value immediately when one exists, while a fresh fetch
// runs in the background and notifies the view via `onFresh` when ready.
//
// Live streams (`*/stats`, `*/logs`) MUST NOT use this layer — they go
// directly through `client.system.stats(...)` etc. A DEBUG assertion guards
// against accidental misuse.

struct CachedClient: Sendable {
    let client: ArcaneClient
    let serverIdentity: String
    let userID: String
    let sessionIdentity: String

    /// Returns a cached value (if fresh) and triggers a background revalidate;
    /// otherwise fetches synchronously through the dedup layer and returns fresh.
    /// Pull-to-refresh callers should pass `refresh: true` to skip the cache read.
    @discardableResult
    func get<T: Codable & Sendable>(
        _ path: String,
        as type: T.Type,
        policy: CachePolicy,
        envID: EnvironmentID,
        refresh: Bool = false,
        onFresh: (@MainActor @Sendable (T) -> Void)? = nil
    ) async throws -> T? {
        #if DEBUG
        assert(!path.hasSuffix("/stats") && !path.hasSuffix("/logs"),
               "ResponseCache must not be used for stream paths: \(path)")
        #endif

        let key = CacheKey(
            serverIdentity: serverIdentity,
            userID: userID,
            sessionIdentity: sessionIdentity,
            envID: envID.rawValue,
            pathWithQuery: path
        )

        if !refresh,
           let hit = await ResponseCache.shared.getEntry(key, as: T.self, ttl: policy.ttl) {
            // Background revalidate — but only when the entry is old enough to
            // be worth the round-trip; fresh hits (rapid tab switches) are
            // served as-is. Errors don't propagate — we have a usable value.
            if hit.age >= policy.revalidateAfter {
                let captured = client
                let onFreshCopy = onFresh
                Task.detached(priority: .utility) {
                    let fresh: T?
                    do {
                        fresh = try await ResponseCache.shared.coalesce(key) {
                            try await captured.rest.get(path) as T
                        }
                    } catch {
                        fresh = nil
                    }
                    if let fresh {
                        await ResponseCache.shared.set(key, value: fresh)
                        if let onFreshCopy {
                            await MainActor.run { onFreshCopy(fresh) }
                        }
                    }
                }
            }
            return hit.value
        }

        // Miss or forced refresh. Fetch through coalesce so two concurrent callers share.
        let captured = client
        let fresh: T = try await ResponseCache.shared.coalesce(key) {
            try await captured.rest.get(path) as T
        }
        await ResponseCache.shared.set(key, value: fresh)
        return fresh
    }

    /// Same as `get(...)`, but for global (non-env-scoped) resources like
    /// `environments`, `users`, `api-keys`, `webhooks`, `settings/*`.
    @discardableResult
    func getGlobal<T: Codable & Sendable>(
        _ path: String,
        as type: T.Type,
        policy: CachePolicy,
        refresh: Bool = false,
        onFresh: (@MainActor @Sendable (T) -> Void)? = nil
    ) async throws -> T? {
        try await get(
            path, as: type, policy: policy,
            envID: EnvironmentID(rawValue: "_global_"),
            refresh: refresh, onFresh: onFresh
        )
    }

    /// List variant of `get(...)`: decodes the response through `LenientArray`
    /// so a single malformed element doesn't fail the whole list. Use for any
    /// `[T]` API endpoint where one bad item shouldn't kill the screen.
    @discardableResult
    func getList<E: Codable & Sendable>(
        _ path: String,
        elementType: E.Type,
        policy: CachePolicy,
        envID: EnvironmentID,
        refresh: Bool = false,
        onFresh: (@MainActor @Sendable ([E]) -> Void)? = nil
    ) async throws -> [E]? {
        let onFreshWrapped: (@MainActor @Sendable (LenientArray<E>) -> Void)?
        if let onFresh {
            onFreshWrapped = { wrapped in onFresh(wrapped.elements) }
        } else {
            onFreshWrapped = nil
        }
        let result: LenientArray<E>? = try await get(
            path, as: LenientArray<E>.self, policy: policy,
            envID: envID, refresh: refresh, onFresh: onFreshWrapped
        )
        return result?.elements
    }

    /// Global variant of `getList(...)` for non-env-scoped list endpoints
    /// (`users`, `environments`, `api-keys`, etc.).
    @discardableResult
    func getListGlobal<E: Codable & Sendable>(
        _ path: String,
        elementType: E.Type,
        policy: CachePolicy,
        refresh: Bool = false,
        onFresh: (@MainActor @Sendable ([E]) -> Void)? = nil
    ) async throws -> [E]? {
        try await getList(
            path, elementType: elementType, policy: policy,
            envID: EnvironmentID(rawValue: "_global_"),
            refresh: refresh, onFresh: onFresh
        )
    }

    /// Custom-fetcher variant that wraps the fetcher result in a `LenientArray`
    /// before caching, so paginated/raw fetchers also benefit from per-item
    /// decode tolerance.
    @discardableResult
    func getListCustom<E: Codable & Sendable>(
        path: String,
        elementType: E.Type,
        policy: CachePolicy,
        envID: EnvironmentID,
        refresh: Bool = false,
        onFresh: (@MainActor @Sendable ([E]) -> Void)? = nil,
        fetcher: @Sendable @escaping () async throws -> [E]
    ) async throws -> [E]? {
        let wrappedFetcher: @Sendable () async throws -> LenientArray<E> = {
            LenientArray(elements: try await fetcher())
        }
        let onFreshWrapped: (@MainActor @Sendable (LenientArray<E>) -> Void)?
        if let onFresh {
            onFreshWrapped = { wrapped in onFresh(wrapped.elements) }
        } else {
            onFreshWrapped = nil
        }
        let result: LenientArray<E>? = try await getCustom(
            path: path, as: LenientArray<E>.self, policy: policy,
            envID: envID, refresh: refresh,
            onFresh: onFreshWrapped, fetcher: wrappedFetcher
        )
        return result?.elements
    }

    /// Fetches and caches a complete paginated collection. The cache key is
    /// intentionally separate from an endpoint's legacy first-page entry.
    @discardableResult
    func getAllPages<E: Codable & Identifiable & Sendable>(
        path: String,
        elementType: E.Type,
        policy: CachePolicy,
        envID: EnvironmentID,
        pageSize: Int = PaginationLoader.defaultPageSize,
        maximumItems: Int = RemoteDataLimits.maximumCollectionItems,
        refresh: Bool = false,
        onFresh: (@MainActor @Sendable ([E]) -> Void)? = nil,
        fetchPage: @Sendable @escaping (_ start: Int, _ limit: Int) async throws -> ResourcePage<E>
    ) async throws -> [E]? where E.ID: Sendable {
        try await getListCustom(
            path: PaginationLoader.cachePath(for: path),
            elementType: elementType,
            policy: policy,
            envID: envID,
            refresh: refresh,
            onFresh: onFresh
        ) {
            try await PaginationLoader.collect(
                pageSize: pageSize,
                maximumItems: maximumItems,
                fetchPage: fetchPage
            )
        }
    }

    /// Global variant of `getAllPages(...)`.
    @discardableResult
    func getAllPagesGlobal<E: Codable & Identifiable & Sendable>(
        path: String,
        elementType: E.Type,
        policy: CachePolicy,
        pageSize: Int = PaginationLoader.defaultPageSize,
        maximumItems: Int = RemoteDataLimits.maximumCollectionItems,
        refresh: Bool = false,
        onFresh: (@MainActor @Sendable ([E]) -> Void)? = nil,
        fetchPage: @Sendable @escaping (_ start: Int, _ limit: Int) async throws -> ResourcePage<E>
    ) async throws -> [E]? where E.ID: Sendable {
        try await getAllPages(
            path: path,
            elementType: elementType,
            policy: policy,
            envID: EnvironmentID(rawValue: "_global_"),
            pageSize: pageSize,
            maximumItems: maximumItems,
            refresh: refresh,
            onFresh: onFresh,
            fetchPage: fetchPage
        )
    }

    /// Same SWR semantics as `get(...)`, but the caller supplies the fetcher.
    /// Use when the underlying call isn't a plain `client.rest.get(...)`
    /// (e.g. custom raw-decode paths like the Volumes list).
    @discardableResult
    func getCustom<T: Codable & Sendable>(
        path: String,
        as type: T.Type,
        policy: CachePolicy,
        envID: EnvironmentID,
        refresh: Bool = false,
        onFresh: (@MainActor @Sendable (T) -> Void)? = nil,
        fetcher: @Sendable @escaping () async throws -> T
    ) async throws -> T? {
        #if DEBUG
        assert(!path.hasSuffix("/stats") && !path.hasSuffix("/logs"),
               "ResponseCache must not be used for stream paths: \(path)")
        #endif
        let key = CacheKey(
            serverIdentity: serverIdentity, userID: userID,
            sessionIdentity: sessionIdentity,
            envID: envID.rawValue, pathWithQuery: path
        )
        if !refresh,
           let hit = await ResponseCache.shared.getEntry(key, as: T.self, ttl: policy.ttl) {
            if hit.age >= policy.revalidateAfter {
                let onFreshCopy = onFresh
                Task.detached(priority: .utility) {
                    let fresh: T?
                    do {
                        fresh = try await ResponseCache.shared.coalesce(key, work: fetcher)
                    } catch {
                        fresh = nil
                    }
                    if let fresh {
                        await ResponseCache.shared.set(key, value: fresh)
                        if let onFreshCopy {
                            await MainActor.run { onFreshCopy(fresh) }
                        }
                    }
                }
            }
            return hit.value
        }
        let fresh: T = try await ResponseCache.shared.coalesce(key, work: fetcher)
        await ResponseCache.shared.set(key, value: fresh)
        return fresh
    }

    /// Invalidate cache entries by matching env + glob-style path patterns.
    /// Pattern matching: literal equality, or a trailing `*` matches a prefix.
    func invalidate(envID: EnvironmentID, paths: [String]) async {
        let env = envID.rawValue
        await ResponseCache.shared.invalidate { key in
            guard key.envID == env else { return false }
            return paths.contains { Self.matches(pattern: $0, path: key.pathWithQuery) }
        }
    }

    /// Invalidate non-environment-scoped paths (settings, webhooks, users, api-keys, etc.).
    func invalidateGlobal(paths: [String]) async {
        await ResponseCache.shared.invalidate { key in
            paths.contains { Self.matches(pattern: $0, path: key.pathWithQuery) }
        }
    }

    nonisolated static func matches(pattern: String, path: String) -> Bool {
        if pattern == path
            || path.hasPrefix(pattern + "?")
            || path.hasPrefix(pattern + "#") {
            return true
        }
        if pattern.hasSuffix("*") {
            return path.hasPrefix(String(pattern.dropLast()))
        }
        return false
    }
}
