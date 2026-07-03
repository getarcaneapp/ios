import Foundation

// Per-resource TTLs for the response cache. Picked to balance freshness with
// the goal of instant screen renders. Live data (stats, logs) never reaches
// the cache layer at all and so is not represented here.

struct CachePolicy: Sendable {
    let ttl: TimeInterval

    /// Minimum age before a cache hit triggers a background revalidation.
    /// Below this the cached value is served as-is — rapid tab switching used
    /// to fire a refetch for every visible row on every appear.
    var revalidateAfter: TimeInterval { min(30, ttl / 4) }

    static let projects         = CachePolicy(ttl: 5 * 60)
    static let environments     = CachePolicy(ttl: 5 * 60)
    static let containersList   = CachePolicy(ttl: 30)
    static let containerDetail  = CachePolicy(ttl: 30)
    static let imagesList       = CachePolicy(ttl: 5 * 60)
    static let imageDetail      = CachePolicy(ttl: 5 * 60)
    static let volumes          = CachePolicy(ttl: 5 * 60)
    static let networks         = CachePolicy(ttl: 5 * 60)
    static let dockerInfo       = CachePolicy(ttl: 2 * 60)
    static let dashboardCounts  = CachePolicy(ttl: 60)
    static let settings         = CachePolicy(ttl: 10 * 60)
    static let webhooks         = CachePolicy(ttl: 10 * 60)
    static let apiKeys          = CachePolicy(ttl: 10 * 60)
    static let users            = CachePolicy(ttl: 10 * 60)
    static let registries       = CachePolicy(ttl: 10 * 60)
    static let templates        = CachePolicy(ttl: 10 * 60)

    static func custom(_ ttl: TimeInterval) -> CachePolicy { CachePolicy(ttl: ttl) }
}
