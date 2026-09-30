import AppIntents
import Foundation
import Arcane

// App-process App Intents: open-in-app navigation, container/project entities,
// and mutation actions for Shortcuts/Siri. Mutation intents are deliberately
// NOT exposed as widget buttons; the widget's only intent is the refresh
// button (RefreshDashboardIntent, widget target).

// MARK: - Tab navigation

nonisolated enum ArcaneTabOption: String, AppEnum {
    case dashboard, containers, projects, updates

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Tab"
    static let caseDisplayRepresentations: [ArcaneTabOption: DisplayRepresentation] = [
        .dashboard: "Dashboard",
        .containers: "Containers",
        .projects: "Projects",
        .updates: "Updates",
    ]

    var tabID: String { AppTab(rawValue: rawValue)?.id ?? AppTab.dashboard.id }
}

struct OpenArcaneTabIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Arcane Tab"
    static let description = IntentDescription("Opens Arcane on a specific tab.")
    static let openAppWhenRun = true

    @Parameter(title: "Tab", default: .dashboard)
    var tab: ArcaneTabOption

    @MainActor
    func perform() async throws -> some IntentResult {
        QuickActionRouter.shared.pendingRoute = .tab(tab.tabID)
        return .result()
    }
}

// MARK: - Entities

nonisolated struct ContainerEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Container"
    static let defaultQuery = ContainerEntityQuery()

    /// "<environmentID>|<containerID>" so the pair survives round-trips.
    var id: String
    var name: String
    var environmentID: String
    var containerID: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    init(environmentID: String, containerID: String, name: String) {
        self.id = "\(environmentID)|\(containerID)"
        self.environmentID = environmentID
        self.containerID = containerID
        self.name = name
    }

    init?(compositeID: String, name: String) {
        let parts = compositeID.split(separator: "|", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        self.init(environmentID: String(parts[0]), containerID: String(parts[1]), name: name)
    }

    static func displayName(for summary: ContainerSummary) -> String {
        let raw = summary.names.first ?? summary.id
        return raw.hasPrefix("/") ? String(raw.dropFirst()) : raw
    }
}

nonisolated struct ContainerEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [ContainerEntity] {
        let client = try IntentClientFactory.makeClient()
        var entities: [ContainerEntity] = []
        for identifier in identifiers {
            guard let entity = ContainerEntity(compositeID: identifier, name: "") else { continue }
            let details = try await RemoteDataLimits.boundedContainerInspect(
                client: client,
                environmentID: EnvironmentID(rawValue: entity.environmentID),
                containerID: entity.containerID
            )
            entities.append(ContainerEntity(
                environmentID: entity.environmentID,
                containerID: details.id,
                name: details.name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            ))
        }
        return entities
    }

    func entities(matching string: String) async throws -> [ContainerEntity] {
        try await listContainers().filter {
            $0.name.localizedCaseInsensitiveContains(string)
        }
    }

    func suggestedEntities() async throws -> [ContainerEntity] {
        Array(try await listContainers().prefix(12))
    }

    /// Containers in the active environment via a short-timeout client.
    private func listContainers() async throws -> [ContainerEntity] {
        let client = try IntentClientFactory.makeClient()
        let envID = IntentClientFactory.activeEnvironmentID
        let response = try await client.containers.list(
            envID: envID,
            query: SearchPaginationSort(start: 0, limit: 50)
        )
        return response.data.map {
            ContainerEntity(
                environmentID: envID.rawValue,
                containerID: $0.id,
                name: ContainerEntity.displayName(for: $0)
            )
        }
    }
}

nonisolated struct ProjectEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Project"
    static let defaultQuery = ProjectEntityQuery()

    var id: String
    var name: String
    var environmentID: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

nonisolated struct ProjectEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [ProjectEntity] {
        let client = try IntentClientFactory.makeClient()
        let envID = IntentClientFactory.activeEnvironmentID
        var entities: [ProjectEntity] = []
        for identifier in identifiers {
            let project = try await client.projects.get(envID: envID, projectID: identifier)
            entities.append(ProjectEntity(id: project.id, name: project.name, environmentID: envID.rawValue))
        }
        return entities
    }

    func entities(matching string: String) async throws -> [ProjectEntity] {
        try await listProjects().filter {
            $0.name.localizedCaseInsensitiveContains(string)
        }
    }

    func suggestedEntities() async throws -> [ProjectEntity] {
        Array(try await listProjects().prefix(12))
    }

    private func listProjects() async throws -> [ProjectEntity] {
        let client = try IntentClientFactory.makeClient()
        let envID = IntentClientFactory.activeEnvironmentID
        let response = try await client.projects.list(
            envID: envID,
            query: SearchPaginationSort(start: 0, limit: 50)
        )
        return response.data.map {
            ProjectEntity(id: $0.id, name: $0.name, environmentID: envID.rawValue)
        }
    }
}

// MARK: - Open-in-app intents

struct OpenContainerIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Container"
    static let description = IntentDescription("Opens a container in Arcane.")
    static let openAppWhenRun = true

    @Parameter(title: "Container")
    var container: ContainerEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        QuickActionRouter.shared.pendingRoute = .container(
            environmentID: container.environmentID,
            id: container.containerID
        )
        return .result()
    }
}

struct OpenProjectIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Project"
    static let description = IntentDescription("Opens a project in Arcane.")
    static let openAppWhenRun = true

    @Parameter(title: "Project")
    var project: ProjectEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        QuickActionRouter.shared.pendingRoute = .project(
            environmentID: project.environmentID,
            id: project.id
        )
        return .result()
    }
}

// MARK: - Mutation intents (Shortcuts/Siri only — never widget buttons)

struct RestartContainerIntent: AppIntent {
    static let title: LocalizedStringResource = "Restart Container"
    static let description = IntentDescription("Restarts a container on your Arcane server.")

    @Parameter(title: "Container")
    var container: ContainerEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await requestConfirmation(
            conditions: [],
            actionName: .do,
            dialog: "Restart \(container.name)?"
        )
        let client = try IntentClientFactory.makeClient()
        try await client.containers.restart(
            envID: EnvironmentID(rawValue: container.environmentID),
            id: container.containerID
        )
        return .result(dialog: "Restarted \(container.name).")
    }
}

struct StartProjectIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Project"
    static let description = IntentDescription("Deploys (starts) a Compose project on your Arcane server.")

    @Parameter(title: "Project")
    var project: ProjectEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await requestConfirmation(
            conditions: [],
            actionName: .do,
            dialog: "Start \(project.name)? This deploys its Compose services."
        )
        let client = try IntentClientFactory.makeClient()
        try await client.projects.deploy(
            envID: EnvironmentID(rawValue: project.environmentID),
            projectID: project.id
        )
        return .result(dialog: "Started \(project.name).")
    }
}

struct StopProjectIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Project"
    static let description = IntentDescription("Brings a Compose project down on your Arcane server.")

    @Parameter(title: "Project")
    var project: ProjectEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await requestConfirmation(
            conditions: [],
            actionName: .do,
            dialog: "Stop \(project.name)? Its containers will go down."
        )
        let client = try IntentClientFactory.makeClient()
        try await client.projects.down(
            envID: EnvironmentID(rawValue: project.environmentID),
            projectID: project.id
        )
        return .result(dialog: "Stopped \(project.name).")
    }
}

// MARK: - App Shortcuts (Siri phrases)

struct ArcaneShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenArcaneTabIntent(),
            phrases: [
                "Open \(.applicationName)",
                "Open \(\.$tab) in \(.applicationName)",
                "Show my \(.applicationName) \(\.$tab)",
                "Check my \(.applicationName) containers",
            ],
            shortTitle: "Open Arcane",
            systemImageName: "server.rack"
        )
        AppShortcut(
            intent: RestartContainerIntent(),
            phrases: [
                "Restart a container in \(.applicationName)",
                "Restart a \(.applicationName) container",
            ],
            shortTitle: "Restart Container",
            systemImageName: "arrow.clockwise"
        )
    }
}
