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
