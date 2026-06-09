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
    let description = """
    Stage a Compose project action: up (deploy/start), down (stop), restart, or redeploy. \
    This does NOT execute — it queues the action for the user to confirm with a button. \
    Always tell the user you've prepared it and are waiting for their confirmation; never claim it ran.
    """

    @Generable
    struct Arguments {
        @Guide(description: "The project's id from a previous listProjects call.")
        var projectId: String
        @Guide(description: "Human-readable project name, for the confirmation prompt.")
        var projectName: String
        @Guide(description: "One of: up (start/deploy), down (stop), restart, redeploy.")
        var action: String
    }

    func call(arguments: Arguments) async throws -> String {
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
