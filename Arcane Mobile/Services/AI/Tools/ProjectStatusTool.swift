import Foundation
import Arcane
import FoundationModels

/// Reports a single project's status and running/total service counts. Looks the
/// project up in the list by id or name (per-service runtime detail is a later
/// enhancement).
@available(iOS 26, *)
struct ProjectStatusTool: Tool {
    let context: ArcaneToolContext

    let name = "getProjectStatus"
    let description = "Get one Compose project's status and how many of its services are running. Pass the project id or name."

    @Generable
    struct Arguments {
        @Guide(description: "The project's id or name (from a previous listProjects call).")
        var project: String
    }

    func call(arguments: Arguments) async throws -> String {
        context.status.report("Checking project status…")
        let items: [ProjectDetails]
        do {
            items = try await context.client.projects.list(
                envID: context.envID,
                query: SearchPaginationSort(start: 0, limit: 200)
            ).data
        } catch {
            return "Couldn't fetch project status: \(error.localizedDescription)"
        }
        let needle = arguments.project.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let p = items.first(where: {
            $0.id == needle || $0.name.localizedCaseInsensitiveCompare(needle) == .orderedSame
        }) else {
            return "No project matching “\(needle)”. Call listProjects to see available projects."
        }
        return "\(p.name): status \(p.status), \(p.runningCount)/\(p.serviceCount) services running."
    }
}
