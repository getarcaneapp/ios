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
    struct Arguments {
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

        let shown = items.prefix(25)
        let lines = shown.map { p in
            "- \(p.name) [\(p.status)] \(p.runningCount)/\(p.serviceCount) running id=\(p.id)"
        }
        let header = "\(items.count) project(s) in \(context.envName)."
        let more = items.count > shown.count ? "\n(+\(items.count - shown.count) more not shown)" : ""
        let body = lines.isEmpty ? "(no matching projects)" : lines.joined(separator: "\n")
        return "\(header)\n\(body)\(more)"
    }
}
