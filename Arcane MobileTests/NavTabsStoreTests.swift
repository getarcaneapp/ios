import Testing

@testable import Arcane_Mobile

@Suite("Native tab configuration")
struct NavTabsStoreTests {
    @Test
    func acceptsFourUniquePinnableDestinations() {
        #expect(
            NavTabsStore.isValidConfiguration([
                .dashboard, .containers, .images, .projects,
            ]))
    }

    @Test
    func rejectsDuplicatesWrongCountsAndNonPinnableDestinations() {
        #expect(
            !NavTabsStore.isValidConfiguration([
                .dashboard, .dashboard, .images, .projects,
            ]))
        #expect(
            !NavTabsStore.isValidConfiguration([
                .dashboard, .containers, .images,
            ]))
        #expect(
            !NavTabsStore.isValidConfiguration([
                .dashboard, .containers, .images, .apiKeys,
            ]))
    }

    @Test
    func unavailablePinnedTabsUseStableAccessibleFallbacks() {
        let available: Set<AppTab> = [
            .dashboard, .containers, .networks, .volumes, .events,
        ]

        let resolved = NavTabsStore.resolveTabs(
            pinned: [.dashboard, .containers, .images, .projects],
            availableTabs: available
        )

        #expect(resolved == [.dashboard, .containers, .networks, .volumes])
    }

    @Test
    func restrictedAccountsCanResolveFewerThanFourTabs() {
        let available: Set<AppTab> = [.dashboard, .containers]

        let resolved = NavTabsStore.resolveTabs(
            pinned: AppTab.mainDefaults,
            availableTabs: available
        )

        #expect(resolved == [.dashboard, .containers])
    }
}
