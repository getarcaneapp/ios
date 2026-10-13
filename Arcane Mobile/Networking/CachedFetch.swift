import Arcane
import Foundation

// Deduplicating wrapper around `client.rest.get`. Concurrent callers for the
// same resource share one in-flight request; every call returns a response
// fetched after it was made (or joined while in flight), never a stored copy.
//
// Live streams (`*/stats`, `*/logs`) MUST NOT use this layer — they go
// directly through `client.system.stats(...)` etc. A DEBUG assertion guards
// against accidental misuse.

struct CachedClient: Sendable {
    let client: ArcaneClient
    let serverIdentity: String
    let userID: String
    let sessionIdentity: String

    @discardableResult
    func get<T: Codable & Sendable>(
        _ path: String,
        as type: T.Type,
        envID: EnvironmentID
    ) async throws -> T {
        let captured = client
        return try await getCustom(path: path, as: type, envID: envID) {
            try await captured.rest.get(path) as T
        }
    }

    /// Same as `get(...)`, but for global (non-env-scoped) resources like
    /// `environments`, `users`, `api-keys`, `webhooks`, `settings/*`.
    @discardableResult
    func getGlobal<T: Codable & Sendable>(_ path: String, as type: T.Type) async throws -> T {
        try await get(path, as: type, envID: Self.globalEnvironment)
    }

    /// List variant of `get(...)`: decodes the response through `LenientArray`
    /// so a single malformed element doesn't fail the whole list. Use for any
    /// `[T]` API endpoint where one bad item shouldn't kill the screen.
    @discardableResult
    func getList<E: Codable & Sendable>(
        _ path: String,
        elementType _: E.Type,
        envID: EnvironmentID
    ) async throws -> [E] {
        try await get(path, as: LenientArray<E>.self, envID: envID).elements
    }

    /// Global variant of `getList(...)` for non-env-scoped list endpoints
    /// (`users`, `environments`, `api-keys`, etc.).
    @discardableResult
    func getListGlobal<E: Codable & Sendable>(_ path: String, elementType: E.Type) async throws -> [E] {
        try await getList(path, elementType: elementType, envID: Self.globalEnvironment)
    }

    /// Custom-fetcher variant for list endpoints.
    @discardableResult
    func getListCustom<E: Sendable>(
        path: String,
        elementType _: E.Type,
        envID: EnvironmentID,
        fetcher: @Sendable @escaping () async throws -> [E]
    ) async throws -> [E] {
        try await getCustom(path: path, as: [E].self, envID: envID, fetcher: fetcher)
    }

    /// Fetches a complete paginated collection. The dedup key is
    /// intentionally separate from an endpoint's first-page request.
    @discardableResult
    func getAllPages<E: Identifiable & Sendable>(
        path: String,
        elementType: E.Type,
        envID: EnvironmentID,
        pageSize: Int = PaginationLoader.defaultPageSize,
        maximumItems: Int = RemoteDataLimits.maximumCollectionItems,
        fetchPage: @Sendable @escaping (_ start: Int, _ limit: Int) async throws -> ResourcePage<E>
    ) async throws -> [E] where E.ID: Sendable {
        try await getListCustom(
            path: PaginationLoader.cachePath(for: path),
            elementType: elementType,
            envID: envID
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
    func getAllPagesGlobal<E: Identifiable & Sendable>(
        path: String,
        elementType: E.Type,
        pageSize: Int = PaginationLoader.defaultPageSize,
        maximumItems: Int = RemoteDataLimits.maximumCollectionItems,
        fetchPage: @Sendable @escaping (_ start: Int, _ limit: Int) async throws -> ResourcePage<E>
    ) async throws -> [E] where E.ID: Sendable {
        try await getAllPages(
            path: path,
            elementType: elementType,
            envID: Self.globalEnvironment,
            pageSize: pageSize,
            maximumItems: maximumItems,
            fetchPage: fetchPage
        )
    }

    /// Same as `get(...)`, but the caller supplies the fetcher.
    /// Use when the underlying call isn't a plain `client.rest.get(...)`
    /// (e.g. custom raw-decode paths like the Volumes list).
    @discardableResult
    func getCustom<T: Sendable>(
        path: String,
        as _: T.Type,
        envID: EnvironmentID,
        fetcher: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        #if DEBUG
            assert(
                !path.hasSuffix("/stats") && !path.hasSuffix("/logs"),
                "ResponseCache must not be used for stream paths: \(path)")
        #endif
        let key = CacheKey(
            serverIdentity: serverIdentity, userID: userID,
            sessionIdentity: sessionIdentity,
            envID: envID.rawValue, pathWithQuery: path
        )
        return try await ResponseCache.shared.coalesce(key, work: fetcher)
    }

    nonisolated static let globalEnvironment = EnvironmentID(rawValue: "_global_")

    /// Invalidate cache entries by matching env + glob-style path patterns.
    /// Pattern matching: literal equality, or a trailing `*` matches a prefix.
    func invalidate(envID: EnvironmentID, paths: [String]) async {
        let env = envID.rawValue
        let server = serverIdentity
        let user = userID
        let session = sessionIdentity
        await ResponseCache.shared.invalidate { key in
            guard key.serverIdentity == server, key.userID == user,
                key.sessionIdentity == session, key.envID == env
            else { return false }
            return paths.contains { Self.matches(pattern: $0, path: key.pathWithQuery) }
        }
    }

    /// Invalidate non-environment-scoped paths (settings, webhooks, users, api-keys, etc.).
    func invalidateGlobal(paths: [String]) async {
        let server = serverIdentity
        let user = userID
        let session = sessionIdentity
        await ResponseCache.shared.invalidate { key in
            guard key.serverIdentity == server, key.userID == user,
                key.sessionIdentity == session
            else { return false }
            return paths.contains { Self.matches(pattern: $0, path: key.pathWithQuery) }
        }
    }

    nonisolated static func matches(pattern: String, path: String) -> Bool {
        if pattern == path
            || path.hasPrefix(pattern + "?")
            || path.hasPrefix(pattern + "#")
        {
            return true
        }
        if pattern.hasSuffix("*") {
            return path.hasPrefix(String(pattern.dropLast()))
        }
        return false
    }
}
