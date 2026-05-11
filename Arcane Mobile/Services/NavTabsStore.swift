import Foundation
import Observation

@Observable
final class NavTabsStore {
    static let shared = NavTabsStore()

    private static let storageKey = "arcane.navBarTabs"
    private static let slotCount = 4

    private(set) var version: Int = 0

    private init() {}

    /// The 4 swappable tabs (Settings is always pinned separately).
    /// Falls back to `AppTab.mainDefaults` on first launch or if persisted data is malformed.
    var pinnedTabs: [AppTab] {
        _ = version
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let ids = try? JSONDecoder().decode([String].self, from: data),
              ids.count == Self.slotCount else {
            return AppTab.mainDefaults
        }
        let resolved = ids.compactMap { AppTab(rawValue: $0) }
        return resolved.count == Self.slotCount ? resolved : AppTab.mainDefaults
    }

    /// Drops admin-only tabs for non-admins and pads with `mainDefaults` so the
    /// returned list always has `slotCount` entries.
    func visibleTabs(isAdmin: Bool) -> [AppTab] {
        var visible = pinnedTabs.filter { isAdmin || !$0.requiresAdmin }
        if visible.count < Self.slotCount {
            for fallback in AppTab.mainDefaults {
                if visible.count == Self.slotCount { break }
                if !visible.contains(fallback) { visible.append(fallback) }
            }
        }
        return Array(visible.prefix(Self.slotCount))
    }

    func swap(pinned: AppTab, with replacement: AppTab) {
        var current = pinnedTabs
        guard let idx = current.firstIndex(of: pinned) else { return }
        current[idx] = replacement
        save(current)
    }

    private func save(_ tabs: [AppTab]) {
        let ids = tabs.map { $0.rawValue }
        if let data = try? JSONEncoder().encode(ids) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
        version &+= 1
    }
}
