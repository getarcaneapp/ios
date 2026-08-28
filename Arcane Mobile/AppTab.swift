import SwiftUI
import Arcane

/// Every destination represented by the shared app navigation model.
/// Pure data — no view types. Use `appTabDestination(_:manager:selectedTab:)`
/// to render the destination view for a tab.
nonisolated enum AppTab: String, CaseIterable, Identifiable, Hashable {
    case dashboard, updates, projects
    case containers, images, imageVulnerabilities, networks, ports, networkTopology, volumes
    case swarm, events, customize, settings
    case templateRegistries, containerRegistries, variables, gitRepositories, gitOps
    case apiKeys, webhooks, authentication, notifications, jobs, users, roles, systemSettings
    case activities, oidcRoleMappings

    enum Section: Hashable, CaseIterable {
        case management, resources, swarm, administration

        var title: String {
            switch self {
            case .management: return "Management"
            case .resources: return "Resources"
            case .swarm: return "Swarm"
            case .administration: return "Administration"
            }
        }
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .updates: return "Updates"
        case .projects: return "Projects"
        case .containers: return "Containers"
        case .images: return "Images"
        case .imageVulnerabilities: return "Vulnerabilities"
        case .networks: return "Networks"
        case .ports: return "Ports"
        case .networkTopology: return "Topology"
        case .volumes: return "Volumes"
        case .swarm: return "Swarm"
        case .events: return "Events"
        case .customize: return "Customize"
        case .settings: return "Settings"
        case .templateRegistries: return "Templates"
        case .containerRegistries: return "Container Registries"
        case .variables: return "Variables"
        case .gitRepositories: return "Git Repositories"
        case .gitOps: return "GitOps"
        case .apiKeys: return "API Keys"
        case .webhooks: return "Webhooks"
        case .authentication: return "Authentication"
        case .notifications: return "Notifications"
        case .jobs: return "Jobs"
        case .users: return "Users"
        case .roles: return "Roles"
        case .systemSettings: return "Environment Settings"
        case .activities: return "Activities"
        case .oidcRoleMappings: return "OIDC Role Mappings"
        }
    }

    var tabBarTitle: String {
        switch self {
        case .containerRegistries: return "Registries"
        case .gitRepositories: return "Git Repos"
        case .systemSettings: return "Environment"
        case .authentication: return "Auth"
        case .oidcRoleMappings: return "OIDC Roles"
        case .activities: return "Activity"
        default: return title
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard: return "chart.bar.fill"
        case .updates: return "arrow.triangle.2.circlepath"
        case .projects: return "square.stack.3d.up.fill"
        case .containers: return "cube.box.fill"
        case .images: return "photo.stack.fill"
        case .imageVulnerabilities: return "shield.lefthalf.filled"
        case .networks: return "network"
        case .ports: return "point.3.connected.trianglepath.dotted"
        case .networkTopology: return "point.topleft.down.curvedto.point.bottomright.up"
        case .volumes: return "externaldrive.fill"
        case .swarm: return "square.stack.3d.up"
        case .events: return "clock.badge.exclamationmark"
        case .customize: return "paintbrush.pointed.fill"
        case .settings: return "gearshape.fill"
        case .templateRegistries: return "doc.text.fill"
        case .containerRegistries: return "shippingbox.fill"
        case .variables: return "curlybraces"
        case .gitRepositories: return "arrow.triangle.branch"
        case .gitOps: return "arrow.triangle.merge"
        case .apiKeys: return "key.fill"
        case .webhooks: return "link.badge.plus"
        case .authentication: return "lock.shield.fill"
        case .notifications: return "bell.badge.fill"
        case .jobs: return "calendar.badge.clock"
        case .users: return "person.2.fill"
        case .roles: return "person.crop.rectangle.stack.fill"
        case .systemSettings: return "slider.horizontal.3"
        case .activities: return "clock.arrow.circlepath"
        case .oidcRoleMappings: return "person.badge.key.fill"
        }
    }

    var iconColor: Color {
        switch self {
        case .dashboard, .projects, .containers, .images, .users, .authentication:
            return .blue
        case .updates, .webhooks: return .green
        case .imageVulnerabilities, .volumes, .activities: return .orange
        case .networks, .variables: return .teal
        case .ports: return .cyan
        case .networkTopology, .swarm: return .mint
        case .events, .notifications: return .red
        case .customize, .containerRegistries, .roles: return .purple
        case .settings, .systemSettings: return .gray
        case .templateRegistries, .gitRepositories, .gitOps, .oidcRoleMappings: return .indigo
        case .apiKeys: return .yellow
        case .jobs: return .pink
        }
    }

    var section: Section {
        switch self {
        case .dashboard, .updates, .projects:
            return .management
        case .containers, .images, .imageVulnerabilities, .networks, .ports,
             .networkTopology, .volumes:
            return .resources
        case .swarm:
            return .swarm
        case .events, .customize, .settings, .templateRegistries, .containerRegistries,
             .variables, .gitRepositories, .gitOps, .apiKeys, .webhooks, .authentication,
             .notifications, .jobs, .users, .roles, .systemSettings, .activities,
             .oidcRoleMappings:
            return .administration
        }
    }

    /// Nested destinations owned by this selectable landing page.
    var children: [AppTab] {
        switch self {
        case .images:
            return [.imageVulnerabilities]
        case .networks:
            return [.ports, .networkTopology]
        case .customize:
            return [.templateRegistries, .containerRegistries, .variables, .gitRepositories]
        case .settings:
            return [.apiKeys, .webhooks, .authentication, .notifications, .jobs, .users, .roles, .systemSettings]
        default:
            return []
        }
    }

    var parent: AppTab? {
        switch self {
        case .imageVulnerabilities: return .images
        case .ports, .networkTopology: return .networks
        case .templateRegistries, .containerRegistries, .variables, .gitRepositories: return .customize
        case .apiKeys, .webhooks, .authentication, .notifications, .jobs, .users, .roles,
             .systemSettings:
            return .settings
        default:
            return nil
        }
    }

    var showsInNavigationMenus: Bool { parent == nil && self != .activities && self != .gitOps && self != .oidcRoleMappings }

    var canPinToBottomBar: Bool {
        switch self {
        case .dashboard, .updates, .projects, .containers, .images, .networks,
             .volumes, .events, .swarm:
            return true
        default:
            return false
        }
    }

    var requiresAdmin: Bool {
        switch self {
        case .customize, .templateRegistries, .containerRegistries, .variables, .gitRepositories,
             .gitOps, .swarm, .apiKeys, .webhooks, .authentication, .notifications, .jobs,
             .users, .roles, .systemSettings, .oidcRoleMappings:
            return true
        default:
            return false
        }
    }

    var requiresV2: Bool {
        switch self {
        case .activities, .variables, .roles, .oidcRoleMappings: return true
        default: return false
        }
    }

    var isEnvironmentScoped: Bool {
        switch self {
        case .containers, .images, .imageVulnerabilities, .projects, .volumes, .networks,
             .ports, .networkTopology, .gitOps, .jobs, .swarm:
            return true
        default:
            return false
        }
    }

    var accessSurfaceIDs: [String] {
        switch self {
        case .dashboard: return ["route.dashboard"]
        case .updates: return ["route.updates"]
        case .projects: return ["route.projects"]
        case .containers: return ["route.containers"]
        case .images: return ["route.images"]
        case .imageVulnerabilities: return ["route.images.vulnerabilities"]
        case .networks: return ["route.networks"]
        case .ports: return ["route.ports"]
        case .networkTopology: return ["route.networks.topology"]
        case .volumes: return ["route.volumes"]
        case .swarm: return ["route.swarm"]
        case .events: return ["route.events"]
        case .customize:
            return ["customize.category.templates", "customize.category.registries", "customize.category.variables", "customize.category.git-repositories"]
        case .settings:
            return ["settings.category.apikeys", "settings.category.webhooks", "settings.category.authentication", "settings.category.notifications", "settings.category.jobschedule", "settings.category.users", "settings.category.roles", "settings.category.appearance", "settings.category.build", "settings.category.timeouts", "settings.category.diagnostics"]
        case .templateRegistries: return ["customize.category.templates"]
        case .containerRegistries: return ["customize.category.registries"]
        case .variables: return ["customize.category.variables"]
        case .gitRepositories: return ["customize.category.git-repositories"]
        case .gitOps: return ["route.environments.gitops"]
        case .apiKeys: return ["settings.category.apikeys"]
        case .webhooks: return ["settings.category.webhooks"]
        case .authentication: return ["settings.category.authentication"]
        case .notifications: return ["settings.category.notifications"]
        case .jobs: return ["settings.category.jobschedule"]
        case .users: return ["settings.category.users"]
        case .roles: return ["settings.category.roles"]
        case .systemSettings:
            return ["settings.category.appearance", "settings.category.build", "settings.category.timeouts", "settings.category.diagnostics"]
        case .activities: return ["route.activities"]
        case .oidcRoleMappings: return ["route.oidc-role-mappings"]
        }
    }

    static let mainDefaults: [AppTab] = [.dashboard, .containers, .images, .projects]
    static var promotable: [AppTab] { allCases.filter { !mainDefaults.contains($0) } }

    static func replacementOptions(
        current: AppTab,
        pinned: Set<AppTab>,
        availableTabs: Set<AppTab>
    ) -> [AppTab] {
        allCases.filter { tab in
            tab.canPinToBottomBar && !pinned.contains(tab) && tab != current && availableTabs.contains(tab)
        }
    }
}

@ViewBuilder
func appTabDestination(
    _ tab: AppTab,
    manager: ArcaneClientManager,
    selectedTab: Binding<String>
) -> some View {
    switch tab {
    case .dashboard: DashboardView(selectedTab: selectedTab)
    case .updates: UpdatesView()
    case .projects:
        ProjectsView(environmentID: manager.activeEnvironmentID, environmentName: manager.activeEnvironmentName)
    case .containers:
        ContainersView(environmentID: manager.activeEnvironmentID, environmentName: manager.activeEnvironmentName)
    case .images:
        ImagesView(environmentID: manager.activeEnvironmentID, environmentName: manager.activeEnvironmentName)
    case .imageVulnerabilities: AllVulnerabilitiesView(environmentID: manager.activeEnvironmentID)
    case .networks:
        NetworksView(environmentID: manager.activeEnvironmentID, environmentName: manager.activeEnvironmentName)
    case .ports: PortsView(environmentID: manager.activeEnvironmentID)
    case .networkTopology: NetworkTopologyView(environmentID: manager.activeEnvironmentID)
    case .volumes:
        VolumesView(environmentID: manager.activeEnvironmentID, environmentName: manager.activeEnvironmentName)
    case .swarm:
        ContentUnavailableView {
            Label("Coming Soon", systemImage: "square.stack.3d.up")
        } description: {
            Text("Swarm management is planned for a future Arcane Mobile update.")
        }
        .navigationTitle("Swarm")
    case .events: EventsView()
    case .customize: NavigationCatalogLandingView(parent: .customize)
    case .settings: SettingsView()
    case .templateRegistries: TemplateBrowserView(embedded: true)
    case .containerRegistries: ContainerRegistriesView()
    case .variables: VariablesView()
    case .gitRepositories: GitRepositoriesView()
    case .gitOps: GitOpsSyncsView(environmentID: manager.activeEnvironmentID)
    case .apiKeys: APIKeysView()
    case .webhooks: WebhooksView()
    case .authentication: AuthenticationSettingsView()
    case .notifications: NotificationSettingsView()
    case .jobs: JobsView(environmentID: manager.activeEnvironmentID)
    case .users: UsersView()
    case .roles: RolesView()
    case .systemSettings: SystemSettingsView()
    case .activities: ActivitiesView()
    case .oidcRoleMappings: OIDCRoleMappingsView()
    }
}
