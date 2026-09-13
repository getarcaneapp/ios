import Foundation

nonisolated enum SidebarUtilityDestination: String {
    case profile
    case appSettings = "app-settings"
}

nonisolated enum SidebarNavigation {
    /// Keep related pages beside their parent while retaining permission filtering.
    static func destinations(in section: AppTab.Section, available: [AppTab]) -> [AppTab] {
        let allowed = Set(available)
        return AppTab.allCases
            .filter { $0.section == section && $0.showsInNavigationMenus && allowed.contains($0) }
            .flatMap { [$0] + $0.children.filter(allowed.contains) }
    }

    static func validSelection(_ selectedID: String, allowedIDs: [String]) -> String {
        allowedIDs.contains(selectedID) ? selectedID : allowedIDs.first ?? AppTab.settings.id
    }
}
