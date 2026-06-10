import Arcane
import FoundationModels

/// Assembles the tool set for a session, with the environment baked into each
/// tool via `ArcaneToolContext`. Read tools run immediately; the two control
/// tools only stage actions into `sink` for user confirmation.
@available(iOS 26, *)
enum AIToolbox {
    static func make(context: ArcaneToolContext, sink: AIPendingActionSink) -> [any Tool] {
        [
            ListContainersTool(context: context),
            InspectContainerTool(context: context),
            ContainerLogsTool(context: context),
            ContainerStatsTool(context: context),
            ListProjectsTool(context: context),
            ProjectStatusTool(context: context),
            ListImagesTool(context: context),
            ListVolumesTool(context: context),
            ListNetworksTool(context: context),
            RecentActivitiesTool(context: context),
            SystemInfoTool(context: context),
            ContainerActionTool(context: context, sink: sink),
            ProjectActionTool(context: context, sink: sink),
        ]
    }
}
