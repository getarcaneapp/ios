import Foundation
import Arcane

// `manager.cached` exposes the stale-while-revalidate cached fetch surface.
// It returns nil if the manager has no client configured, mirroring the
// existing `manager.client` guard pattern used by views.

extension ArcaneClientManager {
    var cached: CachedClient? {
        guard let client else { return nil }
        let identity = (parsedServerURL ?? URL(string: serverURL))
            .map(ServerCacheIdentity.canonical(for:)) ?? serverURL
        return CachedClient(
            client: client,
            serverIdentity: identity,
            userID: currentUser?.id ?? "anon"
        )
    }
}
