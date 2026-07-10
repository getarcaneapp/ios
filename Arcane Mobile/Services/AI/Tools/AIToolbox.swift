import Arcane
import FoundationModels

/// Assembles the tool set for a session, with the environment baked into each
/// tool via `ArcaneToolContext`. Read tools run immediately; the staging tools
/// only register actions into `sink` for user confirmation.
///
/// HARD BUDGET: the on-device model's context window is 4,096 tokens TOTAL —
/// instructions + every tool schema + the whole conversation. Keep the base
/// roster at 12 (13 with v2 activities) by extending topic/action enums instead
/// of adding tools. Every schema word is paid on every turn.
@available(iOS 26, *)
enum AIToolbox {
    static func make(
        context: ArcaneToolContext,
        sink: AIPendingActionSink,
        budget: AIContextBudget
    ) -> [any Tool] {
        var tools: [any Tool] = [
            BudgetedTool(base: ListContainersTool(context: context), budget: budget),
            BudgetedTool(base: GetDashboardTool(context: context), budget: budget),
            BudgetedTool(base: InspectContainerTool(context: context), budget: budget),
            BudgetedTool(base: ListProjectsTool(context: context), budget: budget),
            BudgetedTool(base: ProjectStatusTool(context: context), budget: budget),
            BudgetedTool(base: ListImagesTool(context: context), budget: budget),
            BudgetedTool(base: InspectImageTool(context: context), budget: budget),
            BudgetedTool(base: ListVolumesTool(context: context), budget: budget),
            BudgetedTool(base: ListNetworksTool(context: context), budget: budget),
            BudgetedTool(base: GetOpsInfoTool(context: context), budget: budget),
            BudgetedTool(base: SystemInfoTool(context: context), budget: budget),
            BudgetedTool(base: StageTaskTool(context: context, sink: sink), budget: budget)
        ]
        precondition(
            tools.count == AIContextBudget.baseToolCount,
            "Arcane Assistant base tool count changed without updating its context budget"
        )
        // Activities are v2-only: skipping registration on v1 avoids a dead
        // tool and gives its schema's tokens back to the conversation.
        if context.capabilities.supportsActivities {
            tools.append(BudgetedTool(base: RecentActivitiesTool(context: context), budget: budget))
        }
        precondition(
            tools.count == (context.capabilities.supportsActivities
                ? AIContextBudget.maximumToolCount
                : AIContextBudget.baseToolCount),
            "Arcane Assistant tool roster exceeds its context budget"
        )
        return tools
    }
}
