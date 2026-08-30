import Foundation
import UIKit
import Observation
import Arcane

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

    /// Consumed by the app root. Activity Center presentation deliberately
    /// lives above tabs and sidebar navigation so it can open from anywhere.
    var pendingActivityCenter = false

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

    /// Typed destination from a push notification tap. `ContentView` switches
    /// the environment and holds it until the session has bootstrapped;
    /// resource views consume the detail payload.
    enum PendingRoute: Equatable {
        case tab(String)
        case container(environmentID: String, id: String)
        case image(environmentID: String, id: String)
        case activities
        case events
        case environment(id: String)

        var environmentID: String? {
            switch self {
            case .container(let env, _), .image(let env, _): return env
            case .environment(let id): return id
            case .tab, .activities, .events: return nil
            }
        }
    }

    var pendingRoute: PendingRoute? = nil

    func handle(route: MobilePushRoute) {
        switch route.kind {
        case .tab:
            pendingRoute = .tab(route.tab.flatMap { AppTab(rawValue: $0)?.id } ?? AppTab.dashboard.id)
        case .container:
            guard let env = route.environmentId, let id = route.id else { return }
            pendingRoute = .container(environmentID: env, id: id)
        case .image:
            guard let env = route.environmentId, let id = route.id else { return }
            pendingRoute = .image(environmentID: env, id: id)
        case .activities:
            pendingRoute = .activities
        case .events:
            pendingRoute = .events
        case .environment:
            guard let env = route.environmentId else { return }
            pendingRoute = .environment(id: env)
        }
    }

    private init() {}

    func openActivityCenter() {
        pendingActivityCenter = true
    }

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
