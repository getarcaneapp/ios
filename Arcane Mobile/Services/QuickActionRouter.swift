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

    /// Payload from a widget/intent deep link (`arcane-mobile://open?...`).
    /// Tab switching rides `pendingTabID`; detail views consume the resource
    /// payload when navigation for it exists.
    struct DeepLink: Equatable {
        var tabID: String
        var environmentID: String?
        var containerID: String?
    }

    /// Set by `onOpenURL`. Consumed alongside `pendingTabID`.
    var pendingDeepLink: DeepLink? = nil

    private init() {}

    /// Handles `arcane-mobile://open?tab=<AppTab.rawValue>&env=<id>&container=<id>`.
    /// Returns false for URLs this router doesn't own.
    func handle(url: URL) -> Bool {
        guard url.scheme == "arcane-mobile", url.host == "open" else { return false }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value
        }
        let tabID = value("tab").flatMap { AppTab(rawValue: $0)?.id } ?? AppTab.dashboard.id
        pendingDeepLink = DeepLink(
            tabID: tabID,
            environmentID: value("env"),
            containerID: value("container")
        )
        pendingTabID = tabID
        return true
    }

    func handle(_ shortcut: UIApplicationShortcutItem) -> Bool {
        guard let kind = Shortcut(rawValue: shortcut.type) else { return false }
        pendingTabID = kind.tabID
        return true
    }
}
