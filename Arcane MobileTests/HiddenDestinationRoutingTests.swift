import Foundation
import Testing

@testable import Arcane_Mobile

@Suite("Hidden destination routing")
struct HiddenDestinationRoutingTests {
    @Test
    func authorizedResourceDestinationsUseMoreWhenUnpinned() throws {
        let visible: Set<AppTab> = [.dashboard, .images, .networks, .volumes]
        let available = visible.union([.containers, .projects])
        for tab in [AppTab.containers, .projects] {
            let route = try #require(MainTabView.resolveDestination(
                tab.id, visibleTabs: visible, availableTabs: available
            ))
            #expect(route.selectedTab == .settings)
            #expect(route.moreDestination == tab)
        }
    }

    @Test
    func pinnedDestinationsContinueToSelectTheirTab() throws {
        let visible = Set(AppTab.mainDefaults)
        for tab in AppTab.mainDefaults {
            let route = try #require(MainTabView.resolveDestination(
                tab.id, visibleTabs: visible, availableTabs: visible
            ))
            #expect(route.selectedTab == tab)
            #expect(route.moreDestination == nil)
        }
    }

    @Test
    func hiddenAndPinnedLayoutsCannotBypassAuthorization() {
        let visible: Set<AppTab> = [.dashboard, .containers, .images, .projects]
        let available: Set<AppTab> = [.dashboard, .images]
        #expect(MainTabView.resolveDestination("containers", visibleTabs: visible, availableTabs: available) == nil)
        #expect(MainTabView.resolveDestination("projects", visibleTabs: [], availableTabs: available) == nil)
        #expect(MainTabView.resolveDestination("unknown", visibleTabs: visible, availableTabs: available) == nil)
        let more = MainTabView.resolveDestination(AppTab.settings.id, visibleTabs: [], availableTabs: [])
        #expect(more?.selectedTab == .settings)
        #expect(more?.moreDestination == nil)
    }
}

@Suite("Saved navigation state")
@MainActor
struct SavedNavigationStateTests {
    @Test(arguments: [true, false])
    func initialSelectionRespectsRememberPreference(remember: Bool) throws {
        let suite = "arcane.tests.navigation.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(remember, forKey: "arcane.rememberLastTab")
        defaults.set(AppTab.containers.id, forKey: "arcane.lastSelectedTabID")
        let view = MainTabView(defaults: defaults)
        #expect(view.selectedTab == (remember ? AppTab.containers.id : AppTab.dashboard.id))
        defaults.set(AppTab.images.id, forKey: "arcane.lastSelectedTabID")
        #expect(view.selectedTab == (remember ? AppTab.containers.id : AppTab.dashboard.id))
    }

    @Test(arguments: [nil, "", AppTab.projects.id])
    func missingPreferenceDefaultsToRemembering(saved: String?) throws {
        let suite = "arcane.tests.navigation.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(saved, forKey: "arcane.lastSelectedTabID")
        let view = MainTabView(defaults: defaults)
        #expect(view.selectedTab == (saved?.isEmpty == false ? saved! : AppTab.dashboard.id))
    }
}
