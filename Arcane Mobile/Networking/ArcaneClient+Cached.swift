import Foundation
import Arcane

// `manager.cached` exposes the stale-while-revalidate cached fetch surface.
// It returns nil if the manager has no client configured, mirroring the
// existing `manager.client` guard pattern used by views.

extension ArcaneClientManager {
    var cached: CachedClient? {
        guard let client else { return nil }
        let host = URL(string: serverURL)?.host ?? serverURL
        return CachedClient(
            client: client,
            serverHost: host,
            userID: currentUser?.id ?? "anon"
        )
    }
}
