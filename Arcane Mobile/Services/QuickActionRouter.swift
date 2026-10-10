import Arcane
import Foundation
import Observation
import UIKit

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
    /// lives above tab navigation so it can open from anywhere.
    var pendingActivityCenter = false

    /// Typed destination from widgets, Shortcuts, or notification taps. `ContentView` switches
    /// the environment and holds it until the session has bootstrapped;
    /// resource views consume the detail payload.
    enum PendingRoute: Equatable {
        case tab(String, environmentID: String? = nil)
        case container(environmentID: String, id: String)
        case project(environmentID: String, id: String)
        case image(environmentID: String, id: String)
        case activities
        case events
        case environment(id: String)

        var environmentID: String? {
            switch self {
            case .container(let env, _), .project(let env, _), .image(let env, _): return env
            case .environment(let id): return id
            case .tab(_, let env): return env
            case .activities, .events: return nil
            }
        }
    }

    /// Consuming a route clears its payload, but its identity remains valid
    /// until another destination is requested, even in a different view.
    private(set) var routeGeneration: UInt64 = 0
    var pendingRoute: PendingRoute? = nil {
        didSet {
            if pendingRoute != nil { routeGeneration &+= 1 }
        }
    }

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

    init() {}

    func openActivityCenter() {
        pendingActivityCenter = true
    }

    /// Handles existing widget URLs and optional container/project destinations.
    /// Returns false for URLs this router doesn't own.
    func handle(url: URL) -> Bool {
        guard url.scheme == "arcane-mobile", url.host == "open" else { return false }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value
        }
        let tabID = value("tab").flatMap { AppTab(rawValue: $0)?.id } ?? AppTab.dashboard.id
        if let environmentID = value("env"), let containerID = value("container"), !containerID.isEmpty {
            pendingRoute = .container(environmentID: environmentID, id: containerID)
        } else if let environmentID = value("env"), let projectID = value("project"), !projectID.isEmpty {
            pendingRoute = .project(environmentID: environmentID, id: projectID)
        } else {
            pendingRoute = .tab(tabID, environmentID: value("env"))
        }
        return true
    }

    func handle(_ shortcut: UIApplicationShortcutItem) -> Bool {
        guard let kind = Shortcut(rawValue: shortcut.type) else { return false }
        pendingRoute = .tab(kind.tabID)
        return true
    }
}
