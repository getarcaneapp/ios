import Foundation
import Arcane
import FoundationModels

/// Stages an environment-wide maintenance action (prunes, start/stop-all).
/// No target id, so there is nothing for the model to hallucinate. Like all
/// staging tools, it never executes — it queues a confirmation card.
@available(iOS 26, *)
struct StageMaintenanceTool: Tool {
    let context: ArcaneToolContext
    let sink: AIPendingActionSink

    let name = "stageMaintenance"
    let description = "Stage environment-wide maintenance (prunes, start/stop all containers) for user confirmation. Never executes."

    @Generable
    enum MaintenanceAction {
        case pruneImages
        case pruneVolumes
        case pruneNetworks
        case pruneSystem
        case startAllStopped
        case startAllContainers
        case stopAllContainers
    }

    @Generable
    struct Arguments {
        @Guide(description: "The maintenance action to stage.")
        var action: MaintenanceAction
    }

    func call(arguments: Arguments) async throws -> String {
        context.status.report("Preparing maintenance…")
        let op: MaintenanceOp
        switch arguments.action {
        case .pruneImages: op = .pruneImages
        case .pruneVolumes: op = .pruneVolumes
        case .pruneNetworks: op = .pruneNetworks
        case .pruneSystem: op = .pruneSystem
        case .startAllStopped: op = .startAllStopped
        case .startAllContainers: op = .startAllContainers
        case .stopAllContainers: op = .stopAllContainers
        }
        await sink.register(.maintenance(op))
        return "Staged: \(op.summary) on \(context.envName). Awaiting user confirmation — do not assume it has run."
    }
}
