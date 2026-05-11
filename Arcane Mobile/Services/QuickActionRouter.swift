import Foundation
import UIKit
import Observation

/// Bridges UIApplicationShortcutItem deliveries from the AppDelegate into the
/// SwiftUI world. `MainTabView` observes `pendingTabID` and routes selection.
@Observable
final class QuickActionRouter {
    static let shared = QuickActionRouter()

    enum Shortcut: String {
        case dashboard = "arcane.shortcut.dashboard"
        case containers = "arcane.shortcut.containers"
        case projects = "arcane.shortcut.projects"

        /// Maps a shortcut item type to the `AppTab.id` to select.
        var tabID: String {
            switch self {
            case .dashboard: return AppTab.dashboard.id
            case .containers: return AppTab.containers.id
            case .projects: return AppTab.projects.id
            }
        }
    }

    /// Set by the AppDelegate. `MainTabView` consumes and clears.
    var pendingTabID: String? = nil

    private init() {}

    func handle(_ shortcut: UIApplicationShortcutItem) -> Bool {
        guard let kind = Shortcut(rawValue: shortcut.type) else { return false }
        pendingTabID = kind.tabID
        return true
    }
}
