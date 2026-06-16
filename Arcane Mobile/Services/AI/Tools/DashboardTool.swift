import Foundation
import Arcane
import FoundationModels

/// One-call environment overview: container/image counts plus the dashboard's
/// "needs attention" action items. The model is instructed to start here for
/// "how is everything" questions instead of fanning out list calls.
@available(iOS 26, *)
struct GetDashboardTool: Tool {
    let context: ArcaneToolContext

    let name = "getDashboard"
    let description = "Broad health overview: counts plus items needing attention. Use for dashboard/how-is-everything questions."

    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        context.status.report("Checking the dashboard…")
        let snapshot: DashboardSnapshot
        do {
            snapshot = try await ToolSupport.withTimeout(seconds: 8) {
                try await context.client.dashboard.snapshot(envID: context.envID)
            }
        } catch is ToolSupport.TimeoutError {
            return "(the dashboard did not respond quickly enough; ask for containers, projects, or images to check a narrower area)"
        } catch {
            return ToolSupport.friendlyFailure(error, reading: "the dashboard")
        }

        let c = snapshot.containers.counts
        let i = snapshot.imageUsageCounts
        var lines: [String] = []
        lines.append("Overview of \(context.envName):")
        lines.append("containers: \(ToolSupport.countSummary(c.totalContainers, singular: "container")), \(ToolSupport.countSummary(c.runningContainers, singular: "running container")), \(ToolSupport.countSummary(c.stoppedContainers, singular: "stopped container"))")
        let size = ByteCountFormatter.string(fromByteCount: i.totalImageSize, countStyle: .file)
        lines.append("images: \(ToolSupport.countSummary(i.totalImages, singular: "image")), \(ToolSupport.countSummary(i.imagesUnused, singular: "unused image")), size \(size)")

        let items = snapshot.actionItems.items
        if items.isEmpty {
            lines.append("no items needing attention.")
        } else {
            lines.append("attention items:")
            for item in items.prefix(10) {
                lines.append(ToolSupport.itemLine(name: Self.describe(item), status: item.severity.rawValue, reason: ToolSupport.countSummary(item.count, singular: "issue")))
            }
        }
        return lines.joined(separator: "\n")
    }

    private nonisolated static func describe(_ item: ActionItem) -> String {
        switch item.kind {
        case .stoppedContainers:
            return "stopped containers"
        case .imageUpdates:
            return "image updates available"
        case .actionableVulnerabilities:
            return "actionable vulnerabilities"
        case .expiringKeys:
            return "API keys expiring soon"
        case .unknown(let kind):
            return kind.replacingOccurrences(of: "_", with: " ")
        }
    }
}
