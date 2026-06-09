import Foundation
import Arcane

/// Container lifecycle verbs the assistant may stage. Plain enum (no
/// `FoundationModels` dependency) so `AIPendingAction` stays unrestricted; tools
/// parse the model's string choice into this.
enum ContainerVerb: String, CaseIterable, Sendable {
    case start, stop, restart, pause, unpause, redeploy

    var title: String {
        switch self {
        case .start: return "Start"
        case .stop: return "Stop"
        case .restart: return "Restart"
        case .pause: return "Pause"
        case .unpause: return "Resume"
        case .redeploy: return "Redeploy"
        }
    }
    /// Service-interrupting actions get the app's red extra-friction card.
    var isDestructive: Bool { self == .stop || self == .redeploy }
}

/// Compose project verbs. Raw values double as the REST path suffix
/// (`projects/{id}/{suffix}`), matching `ProjectDetailView`.
enum ProjectVerb: String, CaseIterable, Sendable {
    case up, down, restart, redeploy

    var title: String {
        switch self {
        case .up: return "Deploy"
        case .down: return "Stop"
        case .restart: return "Restart"
        case .redeploy: return "Redeploy"
        }
    }
    var isDestructive: Bool { self == .down || self == .redeploy }
}

/// A state-mutating action the model proposed, staged for the user to confirm.
/// Pure `Sendable` value type: safe to pass through the actor sink and to
/// capture in the MainActor execution closure.
///
/// `execute` reuses the confirmed-correct recipe from
/// `ContainerDetailView.performAction` / `ProjectDetailView.performSimpleAction`.
struct AIPendingAction: Identifiable, Sendable {
    let id: UUID
    let kind: Kind

    enum Kind: Sendable {
        case container(id: String, name: String, verb: ContainerVerb)
        case project(id: String, name: String, verb: ProjectVerb)
    }

    static func container(id: String, name: String, verb: ContainerVerb) -> AIPendingAction {
        AIPendingAction(id: UUID(), kind: .container(id: id, name: name, verb: verb))
    }
    static func project(id: String, name: String, verb: ProjectVerb) -> AIPendingAction {
        AIPendingAction(id: UUID(), kind: .project(id: id, name: name, verb: verb))
    }

    var displayName: String {
        switch kind {
        case let .container(_, name, _): return name
        case let .project(_, name, _): return name
        }
    }

    var isDestructive: Bool {
        switch kind {
        case let .container(_, _, verb): return verb.isDestructive
        case let .project(_, _, verb): return verb.isDestructive
        }
    }

    var mutationKind: ResourceMutationStore.Kind {
        switch kind {
        case .container: return .containers
        case .project: return .projects
        }
    }

    /// Verb title used for buttons ("Stop", "Restart", …).
    var actionTitle: String {
        switch kind {
        case let .container(_, _, verb): return verb.title
        case let .project(_, _, verb): return verb.title
        }
    }

    /// "Stop “redis”?" — confirmation card headline.
    var confirmationTitle: String { "\(actionTitle) “\(displayName)”?" }

    /// Lowercase phrase fed back to the model ("stop container redis").
    var summary: String {
        switch kind {
        case let .container(_, name, verb): return "\(verb.rawValue) container \(name)"
        case let .project(_, name, verb): return "\(verb.title.lowercased()) project \(name)"
        }
    }

    /// Cache globs to invalidate after the action lands (same set the manual
    /// detail views invalidate).
    func cachePaths(client: ArcaneClient, envID: EnvironmentID) -> [String] {
        switch kind {
        case .container:
            return [
                client.rest.environmentPath(envID, "containers"),
                client.rest.environmentPath(envID, "containers/*")
            ]
        case .project:
            return [
                client.rest.environmentPath(envID, "projects"),
                client.rest.environmentPath(envID, "projects/*")
            ]
        }
    }

    /// Runs the real SDK call. `client`/`envID` are `Sendable`, so this is safe
    /// to await from the MainActor service after the user confirms.
    @discardableResult
    func execute(client: ArcaneClient, envID: EnvironmentID) async throws -> String {
        switch kind {
        case let .container(id, name, verb):
            switch verb {
            case .start:    try await client.containers.start(envID: envID, id: id)
            case .stop:     try await client.containers.stop(envID: envID, id: id)
            case .restart:  try await client.containers.restart(envID: envID, id: id)
            case .pause:    try await client.containers.pause(envID: envID, id: id)
            case .unpause:  try await client.containers.unpause(envID: envID, id: id)
            case .redeploy:
                let path = client.rest.environmentPath(envID, "containers/\(id)/redeploy")
                let _: ContainerSummary = try await client.rest.post(path, body: String?.none)
            }
            return "\(verb.title) succeeded for \(name)."
        case let .project(id, name, verb):
            let path = client.rest.environmentPath(envID, "projects/\(id)/\(verb.rawValue)")
            let _: DataResponse<String> = try await client.rest.post(path, body: String?.none)
            return "\(verb.title) succeeded for project \(name)."
        }
    }
}
