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
    let description = "Health overview: counts plus items needing attention. Best first call for general questions."

    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        context.status.report("Checking the dashboard…")
        let snapshot: DashboardSnapshot
        do {
            snapshot = try await context.client.dashboard.snapshot(envID: context.envID)
        } catch {
            return ToolSupport.friendlyFailure(error, reading: "the dashboard")
        }

        let c = snapshot.containers.counts
        let i = snapshot.imageUsageCounts
        var lines: [String] = []
        lines.append("Overview of \(context.envName):")
        lines.append("Containers: \(c.runningContainers) running, \(c.stoppedContainers) stopped (\(c.totalContainers) total)")
        let size = ByteCountFormatter.string(fromByteCount: i.totalImageSize, countStyle: .file)
        lines.append("Images: \(i.totalImages) total, \(i.imagesUnused) unused, \(size)")

        let items = snapshot.actionItems.items
        if items.isEmpty {
            lines.append("Nothing needs attention.")
        } else {
            lines.append("Needs attention:")
            for item in items.prefix(10) {
                lines.append("- [\(item.severity.rawValue)] \(Self.describe(item))")
            }
        }
        return lines.joined(separator: "\n")
    }

    private nonisolated static func describe(_ item: ActionItem) -> String {
        switch item.kind {
        case .stoppedContainers: return "\(item.count) stopped container(s)"
        case .imageUpdates: return "\(item.count) image update(s) available"
        case .actionableVulnerabilities: return "\(item.count) actionable vulnerabilit(ies)"
        case .expiringKeys: return "\(item.count) API key(s) expiring soon"
        case .unknown(let kind): return "\(item.count) \(kind.replacingOccurrences(of: "_", with: " "))"
        }
    }
}
