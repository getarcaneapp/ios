import SwiftUI
import Arcane

/// Every destination that can live in the bottom nav bar.
/// Pure data — no view types. Use `appTabDestination(_:manager:selectedTab:)`
/// to render the destination view for a tab.
enum AppTab: String, CaseIterable, Identifiable, Hashable {
    case dashboard, containers, images, projects
    case volumes, networks
    case users, apiKeys, containerRegistries, templateRegistries,
         notifications, webhooks, systemSettings, authentication, builds

    enum Section: Hashable {
        case main, resources, administration
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
        case .users: return "Users"
        case .apiKeys: return "API Keys"
        case .containerRegistries: return "Container Registries"
        case .templateRegistries: return "Template Registries"
        case .notifications: return "Notifications"
        case .webhooks: return "Webhooks"
        case .systemSettings: return "System Settings"
        case .authentication: return "Authentication"
        case .builds: return "Builds"
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
        case .users: return "person.2.fill"
        case .apiKeys: return "key.fill"
        case .containerRegistries: return "shippingbox.fill"
        case .templateRegistries: return "doc.text.fill"
        case .notifications: return "bell.badge.fill"
        case .webhooks: return "link.badge.plus"
        case .systemSettings: return "slider.horizontal.3"
        case .authentication: return "lock.shield.fill"
        case .builds: return "hammer.fill"
        }
    }

    var iconColor: Color {
        switch self {
        case .dashboard, .containers, .images, .projects: return .blue
        case .volumes: return .orange
        case .networks: return .teal
        case .users: return .blue
        case .apiKeys: return .yellow
        case .containerRegistries: return .purple
        case .templateRegistries: return .indigo
        case .notifications: return .red
        case .webhooks: return .green
        case .systemSettings: return .gray
        case .authentication: return .blue
        case .builds: return .orange
        }
    }

    var section: Section {
        switch self {
        case .dashboard:
            return .main
        case .containers, .images, .projects, .volumes, .networks:
            return .resources
        case .users, .apiKeys, .containerRegistries, .templateRegistries,
             .notifications, .webhooks, .systemSettings, .authentication, .builds:
            return .administration
        }
    }

    var requiresAdmin: Bool { section == .administration }

    static let mainDefaults: [AppTab] = [.dashboard, .containers, .images, .projects]
    static var promotable: [AppTab] { AppTab.allCases.filter { $0.section != .main } }
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
    case .builds:
        BuildSettingsView()
    }
}
