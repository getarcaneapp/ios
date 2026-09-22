import Foundation
import Observation

@Observable
final class NavTabsStore {
    static let shared = NavTabsStore()

    private static let storageKey = "arcane.navBarTabs"
    private nonisolated static let slotCount = 4

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
        return Self.isValidConfiguration(resolved) ? resolved : AppTab.mainDefaults
    }

    /// Drops tabs the authenticated session cannot reach, then fills empty
    /// slots with other available primary destinations. A restricted account
    /// may legitimately have fewer than four reachable destinations.
    func visibleTabs(availableTabs: Set<AppTab>) -> [AppTab] {
        Self.resolveTabs(pinned: pinnedTabs, availableTabs: availableTabs)
    }

    nonisolated static func resolveTabs(
        pinned: [AppTab],
        availableTabs: Set<AppTab>
    ) -> [AppTab] {
        var visible = pinned.filter { tab in
            tab.canPinToBottomBar
                && availableTabs.contains(tab)
        }
        if visible.count < Self.slotCount {
            for fallback in AppTab.mainDefaults {
                if visible.count == Self.slotCount { break }
                if availableTabs.contains(fallback), !visible.contains(fallback) {
                    visible.append(fallback)
                }
            }
        }
        if visible.count < Self.slotCount {
            for fallback in AppTab.allCases where fallback.canPinToBottomBar {
                if visible.count == Self.slotCount { break }
                if availableTabs.contains(fallback), !visible.contains(fallback) {
                    visible.append(fallback)
                }
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

    @discardableResult
    func setPinnedTabs(_ tabs: [AppTab]) -> Bool {
        guard Self.isValidConfiguration(tabs) else { return false }
        save(tabs)
        return true
    }

    nonisolated static func isValidConfiguration(_ tabs: [AppTab]) -> Bool {
        tabs.count == slotCount
            && Set(tabs).count == slotCount
            && tabs.allSatisfy(\.canPinToBottomBar)
    }

    func resetToDefaults() {
        UserDefaults.standard.removeObject(forKey: Self.storageKey)
        version &+= 1
    }

    private func save(_ tabs: [AppTab]) {
        let ids = tabs.map { $0.rawValue }
        if let data = try? JSONEncoder().encode(ids) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
        version &+= 1
    }
}
