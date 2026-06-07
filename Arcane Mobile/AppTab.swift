import SwiftUI
import Arcane

/// Every destination that can live in the bottom nav bar.
/// Pure data — no view types. Use `appTabDestination(_:manager:selectedTab:)`
/// to render the destination view for a tab.
enum AppTab: String, CaseIterable, Identifiable, Hashable {
    case dashboard, containers, images, projects
    case volumes, networks, ports, updates, activities, events
    case gitRepositories, gitOps, swarm
    case users, apiKeys, containerRegistries, templateRegistries,
         notifications, webhooks, systemSettings, authentication, jobs,
         roles, oidcRoleMappings

    enum Section: Hashable {
        case management, resources, swarm, administration
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .containers: return "Containers"
        case .images: return "Images"
        case .projects: return "Projects"
        case .volumes: return "Volumes"
        case .networks: return "Networks"
        case .ports: return "Ports"
        case .updates: return "Updates"
        case .activities: return "Activities"
        case .events: return "Events"
        case .gitRepositories: return "Git Repositories"
        case .gitOps: return "GitOps"
        case .swarm: return "Swarm"
        case .users: return "Users"
        case .apiKeys: return "API Keys"
        case .containerRegistries: return "Container Registries"
        case .templateRegistries: return "Template Registries"
        case .notifications: return "Notifications"
        case .webhooks: return "Webhooks"
        case .systemSettings: return "System Settings"
        case .authentication: return "Authentication"
        case .jobs: return "Jobs"
        case .roles: return "Roles"
        case .oidcRoleMappings: return "OIDC Role Mappings"
        }
    }

    /// Shorter label used in the bottom tab bar where horizontal space is
    /// tight — multi-word titles get truncated or wrap awkwardly. Falls back
    /// to `title` for tabs whose name already fits.
    var tabBarTitle: String {
        switch self {
        case .containerRegistries: return "Registries"
        case .templateRegistries: return "Templates"
        case .gitRepositories: return "Git Repos"
        case .systemSettings: return "System"
        case .authentication: return "Auth"
        case .oidcRoleMappings: return "OIDC Roles"
        case .activities: return "Activity"
        default: return title
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard: return "chart.bar.fill"
        case .containers: return "cube.box.fill"
        case .images: return "photo.stack.fill"
        case .projects: return "square.stack.3d.up.fill"
        case .volumes: return "externaldrive.fill"
        case .networks: return "network"
        case .ports: return "point.3.connected.trianglepath.dotted"
        case .updates: return "arrow.triangle.2.circlepath"
        case .activities: return "clock.arrow.circlepath"
        case .events: return "clock.badge.exclamationmark"
        case .gitRepositories: return "arrow.triangle.branch"
        case .gitOps: return "arrow.triangle.merge"
        case .swarm: return "square.stack.3d.up"
        case .users: return "person.2.fill"
        case .apiKeys: return "key.fill"
        case .containerRegistries: return "shippingbox.fill"
        case .templateRegistries: return "doc.text.fill"
        case .notifications: return "bell.badge.fill"
        case .webhooks: return "link.badge.plus"
        case .systemSettings: return "slider.horizontal.3"
        case .authentication: return "lock.shield.fill"
        case .jobs: return "calendar.badge.clock"
        case .roles: return "person.crop.rectangle.stack.fill"
        case .oidcRoleMappings: return "person.badge.key.fill"
        }
    }

    var iconColor: Color {
        switch self {
        case .dashboard, .containers, .images, .projects: return .blue
        case .volumes: return .orange
        case .networks: return .teal
        case .ports: return .cyan
        case .updates: return .green
        case .activities: return .orange
        case .events: return .red
        case .gitRepositories, .gitOps: return .indigo
        case .swarm: return .mint
        case .users: return .blue
        case .apiKeys: return .yellow
        case .containerRegistries: return .purple
        case .templateRegistries: return .indigo
        case .notifications: return .red
        case .webhooks: return .green
        case .systemSettings: return .gray
        case .authentication: return .blue
        case .jobs: return .pink
        case .roles: return .purple
        case .oidcRoleMappings: return .indigo
        }
    }

    var section: Section {
        switch self {
        case .dashboard, .projects, .containerRegistries, .templateRegistries, .gitRepositories, .gitOps:
            return .management
        case .containers, .images, .updates, .activities, .networks, .ports, .volumes, .jobs:
            return .resources
        case .swarm:
            return .swarm
        case .events, .users, .apiKeys, .notifications, .webhooks, .systemSettings, .authentication,
             .roles, .oidcRoleMappings:
            return .administration
        }
    }

    /// Whether this tab makes sense pinned to the bottom bar — a primary content
    /// or resource view you navigate to often. Settings, admin, and one-off
    /// config pages (users, registries, auth, webhooks, jobs, …) are excluded:
    /// they live under Settings, so the long-press replace picker never offers
    /// them as bar tabs. They stay fully reachable via the Settings list.
    var canPinToBottomBar: Bool {
        switch self {
        case .dashboard, .containers, .images, .projects,
             .volumes, .networks, .ports,
             .updates, .activities, .events, .swarm:
            return true
        case .gitRepositories, .gitOps,
             .containerRegistries, .templateRegistries,
             .jobs, .users, .apiKeys, .notifications, .webhooks,
             .systemSettings, .authentication, .roles, .oidcRoleMappings:
            return false
        }
    }

    var requiresAdmin: Bool {
        switch self {
        case .containerRegistries, .templateRegistries, .gitRepositories, .gitOps,
             .jobs, .swarm,
             .users, .apiKeys, .notifications, .webhooks, .systemSettings, .authentication,
             .roles, .oidcRoleMappings:
            return true
        case .dashboard, .projects, .containers, .images, .updates, .activities, .networks, .ports, .volumes, .events:
            return false
        }
    }

    /// Whether this tab requires a v2 RBAC server. On v1 servers, tabs with
    /// `requiresV2 == true` are hidden — the underlying endpoints don't exist.
    var requiresV2: Bool {
        switch self {
        case .activities, .roles, .oidcRoleMappings: return true
        default: return false
        }
    }

    /// Whether the destination view reads from `manager.activeEnvironmentID`.
    /// MainTabView ties these tabs' view identity to the active env so they
    /// rebuild — and capture the new env — when the user switches environments.
    /// Without this, background tabs hold the env captured at first build
    /// (often the .localDocker default "0") and pull-to-refresh hits the wrong env.
    var isEnvironmentScoped: Bool {
        switch self {
        case .dashboard, .containers, .images, .projects, .volumes, .networks,
             .ports, .gitOps, .jobs:
            return true
        case .activities, .updates, .events, .gitRepositories, .users, .apiKeys,
             .containerRegistries, .templateRegistries,
             .notifications, .webhooks, .systemSettings, .authentication,
             .swarm, .roles, .oidcRoleMappings:
            return false
        }
    }

    static let mainDefaults: [AppTab] = [.dashboard, .containers, .images, .projects]
    static var promotable: [AppTab] { AppTab.allCases.filter { !AppTab.mainDefaults.contains($0) } }

    /// Tabs eligible to replace `current` in the bottom bar: every bottom-bar-
    /// eligible tab not already pinned, minus `current` itself, gated by admin /
    /// v2 availability. Flat (declaration order, no section grouping) — callers
    /// group if they want. Shared by `TabSwapSheet` (iOS 18) and
    /// `TabReplaceCallout` (iOS 26).
    static func replacementOptions(
        current: AppTab,
        pinned: Set<AppTab>,
        isAdmin: Bool,
        supportsV2: Bool
    ) -> [AppTab] {
        AppTab.allCases.filter { tab in
            tab.canPinToBottomBar
                && !pinned.contains(tab)
                && tab != current
                && (isAdmin || !tab.requiresAdmin)
                && (supportsV2 || !tab.requiresV2)
        }
    }
}

/// Single source of truth for building a destination view from an AppTab.
/// `selectedTab` is only consumed by Dashboard's quick-jump cards; other
/// destinations ignore it.
@ViewBuilder
func appTabDestination(
    _ tab: AppTab,
    manager: ArcaneClientManager,
    selectedTab: Binding<String>
) -> some View {
    switch tab {
    case .dashboard:
        DashboardView(selectedTab: selectedTab)
    case .containers:
        ContainersView(
            environmentID: manager.activeEnvironmentID,
            environmentName: manager.activeEnvironmentName
        )
    case .images:
        ImagesView(
            environmentID: manager.activeEnvironmentID,
            environmentName: manager.activeEnvironmentName
        )
    case .projects:
        ProjectsView(
            environmentID: manager.activeEnvironmentID,
            environmentName: manager.activeEnvironmentName
        )
    case .volumes:
        VolumesView(
            environmentID: manager.activeEnvironmentID,
            environmentName: manager.activeEnvironmentName
        )
    case .networks:
        NetworksView(
            environmentID: manager.activeEnvironmentID,
            environmentName: manager.activeEnvironmentName
        )
    case .ports:
        PortsView(environmentID: manager.activeEnvironmentID)
    case .updates:
        UpdatesView()
    case .activities:
        ActivitiesView()
    case .events:
        EventsView()
    case .gitRepositories:
        GitRepositoriesView()
    case .gitOps:
        GitOpsSyncsView(environmentID: manager.activeEnvironmentID)
    case .swarm:
        SwarmView()
    case .users:
        UsersView()
    case .apiKeys:
        APIKeysView()
    case .containerRegistries:
        ContainerRegistriesView()
    case .templateRegistries:
        TemplateRegistriesView()
    case .notifications:
        NotificationSettingsView()
    case .webhooks:
        WebhooksView()
    case .systemSettings:
        SystemSettingsView()
    case .authentication:
        AuthenticationSettingsView()
    case .jobs:
        JobsView(environmentID: manager.activeEnvironmentID)
    case .roles:
        RolesView()
    case .oidcRoleMappings:
        OIDCRoleMappingsView()
    }
}
