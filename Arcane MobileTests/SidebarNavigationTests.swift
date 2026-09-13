import Testing
@testable import Arcane_Mobile

@Suite("Sidebar navigation")
struct SidebarNavigationTests {
    @Test func selectionSurvivesPresentationChanges() {
        let destinations = [AppTab.containers.id, AppTab.images.id, SidebarUtilityDestination.profile.rawValue]
        for destination in destinations {
            #expect(SidebarNavigation.validSelection(destination, allowedIDs: destinations) == destination)
        }
    }

    @Test func revokedDestinationFallsBackToAccessiblePage() {
        #expect(SidebarNavigation.validSelection(AppTab.users.id, allowedIDs: [AppTab.dashboard.id]) == AppTab.dashboard.id)
        #expect(SidebarNavigation.validSelection("removed-page", allowedIDs: []) == AppTab.settings.id)
    }

    @Test func relatedPagesFollowTheirParentAndRespectPermissions() {
        let available: [AppTab] = [.images, .imageVulnerabilities, .containers]
        let rows = SidebarNavigation.destinations(in: AppTab.images.section, available: available)
        #expect(rows.contains(.images))
        #expect(rows.contains(.imageVulnerabilities))
        #expect(!rows.contains(.ports))
        #expect(Set(rows).count == rows.count)
        let parentIndex = rows.firstIndex(of: .images)!
        #expect(rows[parentIndex + 1] == .imageVulnerabilities)
    }
}
