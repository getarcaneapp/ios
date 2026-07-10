import Foundation
import Arcane
import FoundationModels

/// Lists Compose projects with status and running/total service counts.
@available(iOS 26, *)
struct ListProjectsTool: Tool {
    let context: ArcaneToolContext

    let name = "listProjects"
    let description = "List Compose projects with status and running/total service counts."

    @Generable
    struct Arguments: Sendable {
        @Guide(description: "Name substring filter.")
        var filter: String?
    }

    func call(arguments: Arguments) async throws -> String {
        context.status.report("Checking projects…")
        var items: [ProjectDetails]
        do {
            items = try await context.client.projects.list(
                envID: context.envID,
                query: SearchPaginationSort(start: 0, limit: 200)
            ).data
        } catch {
            return ToolSupport.friendlyFailure(error, reading: "projects")
        }
        if let filter = arguments.filter?.trimmingCharacters(in: .whitespacesAndNewlines), !filter.isEmpty {
            items = items.filter { $0.name.localizedCaseInsensitiveContains(filter) }
        }

        let header = "\(ToolSupport.countSummary(items.count, singular: "project")) in \(ToolSupport.displayName(context.envName, fallback: "environment"))."
        let lines = ToolSupport.truncatedLines(items, limit: 25, itemSingular: "project") { p in
            let reason = "\(p.runningCount)/\(p.serviceCount) services running"
            return ToolSupport.itemLine(
                name: ToolSupport.displayName(p.name),
                status: ToolSupport.safeText(p.status),
                reason: reason,
                internalId: p.id
            )
        }
        let body = lines.isEmpty
            ? "(no matching projects found in \(ToolSupport.displayName(context.envName, fallback: "environment")))"
            : lines.joined(separator: "\n")
        return "\(header)\n\(body)"
    }
}
