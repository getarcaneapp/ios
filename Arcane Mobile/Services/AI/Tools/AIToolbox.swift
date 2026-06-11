import Arcane
import FoundationModels

/// Assembles the tool set for a session, with the environment baked into each
/// tool via `ArcaneToolContext`. Read tools run immediately; the staging tools
/// only register actions into `sink` for user confirmation.
///
/// HARD BUDGET: the on-device model's context window is ~4,096 tokens TOTAL —
/// instructions + every tool schema + the whole conversation. A 24-tool set
/// measured 4,717 tokens before the first reply. Keep this roster at ~16 by
/// extending a topic enum instead of adding a tool, and keep descriptions
/// terse — every word here is paid on every single turn.
@available(iOS 26, *)
enum AIToolbox {
    static func make(context: ArcaneToolContext, sink: AIPendingActionSink) -> [any Tool] {
        var tools: [any Tool] = [
            GetDashboardTool(context: context),
            ListContainersTool(context: context),
            InspectContainerTool(context: context),     // details / logs / stats
            ListProjectsTool(context: context),
            ProjectStatusTool(context: context),        // status / compose / logs
            ListImagesTool(context: context),
            InspectImageTool(context: context),         // details / updates / cves
            ListVolumesTool(context: context),          // list / details / files / backups
            ListNetworksTool(context: context),         // list / topology / inspect / ports
            GetOpsInfoTool(context: context),           // registries…builds / gitops
            SystemInfoTool(context: context),
            ContainerActionTool(context: context, sink: sink),
            ProjectActionTool(context: context, sink: sink),
            StageMaintenanceTool(context: context, sink: sink),
            StageTaskTool(context: context, sink: sink),
        ]
        // Activities are v2-only: skipping registration on v1 avoids a dead
        // tool and gives its schema's tokens back to the conversation.
        if context.capabilities.supportsActivities {
            tools.append(RecentActivitiesTool(context: context))
        }
        return tools
    }
}
