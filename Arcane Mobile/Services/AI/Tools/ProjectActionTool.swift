import Foundation
import Arcane
import FoundationModels

/// Stages a Compose project action (deploy/up, stop/down, restart, redeploy).
/// Like `ContainerActionTool`, it only queues the action for user confirmation.
@available(iOS 26, *)
struct ProjectActionTool: Tool {
    let context: ArcaneToolContext
    let sink: AIPendingActionSink

    let name = "controlProject"
    let description = "Stage a project action (up, down, restart, redeploy) for user confirmation. Never executes."

    @Generable
    struct Arguments {
        @Guide(description: "Project id from listProjects.")
        var projectId: String
        @Guide(description: "Project name for the prompt.")
        var projectName: String
        @Guide(description: "up, down, restart, or redeploy.")
        var action: String
    }

    func call(arguments: Arguments) async throws -> String {
        context.status.report("Preparing action…")
        let raw = arguments.action.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let verb: ProjectVerb? = switch raw {
        case "up", "start", "deploy": .up
        case "down", "stop": .down
        case "restart": .restart
        case "redeploy", "recreate": .redeploy
        default: ProjectVerb(rawValue: raw)
        }
        guard let verb else {
            return "Unknown action “\(arguments.action)”. Valid actions: up, down, restart, redeploy."
        }
        await sink.register(.project(id: arguments.projectId, name: arguments.projectName, verb: verb))
        return "Staged \(verb.rawValue.capitalized) for project “\(arguments.projectName)”. Awaiting user confirmation — do not assume it has run."
    }
}
