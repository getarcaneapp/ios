import Foundation
import Arcane
import FoundationModels

/// Stages a container lifecycle action. Never executes — it registers a
/// `PendingAction` for the user to confirm with a button, then returns a string
/// telling the model the action is queued (not done).
@available(iOS 26, *)
struct ContainerActionTool: Tool {
    let context: ArcaneToolContext
    let sink: AIPendingActionSink

    let name = "controlContainer"
    let description = "Stage a container action (start, stop, restart, pause, unpause, redeploy) for user confirmation. Never executes."

    @Generable
    struct Arguments {
        @Guide(description: "Container id from listContainers.")
        var containerId: String
        @Guide(description: "Container name for the prompt.")
        var containerName: String
        @Guide(description: "start, stop, restart, pause, unpause, or redeploy.")
        var action: String
    }

    func call(arguments: Arguments) async throws -> String {
        context.status.report("Preparing action…")
        let raw = arguments.action.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard let verb = ContainerVerb(rawValue: raw) else {
            let valid = ContainerVerb.allCases.map(\.rawValue).joined(separator: ", ")
            return "Unknown action “\(arguments.action)”. Valid actions: \(valid)."
        }
        await sink.register(.container(id: arguments.containerId, name: arguments.containerName, verb: verb))
        return "Staged \(verb.rawValue.capitalized) for “\(arguments.containerName)”. Awaiting user confirmation — do not assume it has run."
    }
}
