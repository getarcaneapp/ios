import Foundation
import Arcane

/// Lightweight value type that wraps `ArcaneClientManager` and exposes
/// ergonomic permission checks against the current user + active environment.
///
/// New features should prefer `manager.permissions.has(...)` over the coarse
/// `currentUser?.isAdmin` gate. Coarse admin gating on existing tabs stays
/// in place via `AppTab.requiresAdmin` — this helper enables finer-grained
/// per-action checks as features evolve.
@MainActor
struct Permissions {
    let manager: ArcaneClientManager

    /// True iff the server is a v2 RBAC server. On v1 servers, permission
    /// queries fall back to `isAdmin` (admins receive everything, non-admins
    /// receive nothing).
    var supportsRBAC: Bool {
        manager.serverCapabilities?.supportsRoleManagement == true
    }

    /// True iff the current user is a global admin. Alias for
    /// `currentUser?.isAdmin == true`.
    var isAdmin: Bool {
        manager.currentUser?.isAdmin == true
    }

    /// Whether the user holds `perm` in the currently-active environment.
    /// Falls back to `isAdmin` on v1 servers.
    func has(_ perm: String) -> Bool {
        has(perm, in: manager.activeEnvironmentID)
    }

    /// Whether the user holds `perm` in the given environment. Pass
    /// `EnvironmentID?` of nil to check only the global / org-level bucket.
    func has(_ perm: String, in envID: EnvironmentID?) -> Bool {
        guard let user = manager.currentUser else { return false }
        return user.hasPermission(perm, environmentID: envID?.rawValue)
    }

    /// Whether the user holds any of `perms` in the currently-active env.
    func hasAny(_ perms: [String]) -> Bool {
        hasAny(perms, in: manager.activeEnvironmentID)
    }

    func hasAny(_ perms: [String], in envID: EnvironmentID?) -> Bool {
        guard let user = manager.currentUser else { return false }
        return user.hasAnyPermission(perms, environmentID: envID?.rawValue)
    }

    /// True iff the current user can list roles (required to enter the
    /// Roles management screen). On v1 servers, falls back to `isAdmin`.
    var canManageRoles: Bool {
        guard let user = manager.currentUser else { return false }
        if !supportsRBAC { return user.isAdmin }
        return user.isGlobalAdmin || user.hasPermission(Permission.Roles.list)
    }

    /// True iff the current user can manage OIDC role mappings. Mapping
    /// management is reserved for global admins server-side.
    var canManageOIDCMappings: Bool {
        guard let user = manager.currentUser else { return false }
        if !supportsRBAC { return user.isAdmin }
        return user.isGlobalAdmin
    }
}

extension ArcaneClientManager {
    /// Returns a `Permissions` view bound to this manager. Cheap to recreate
    /// on every SwiftUI body evaluation.
    @MainActor
    var permissions: Permissions { Permissions(manager: self) }
}
