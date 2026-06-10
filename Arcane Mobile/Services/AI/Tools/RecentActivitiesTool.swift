import Foundation
import Arcane
import FoundationModels

/// Reads the most recent activities (deploys, pulls, prunes, scans…) so the
/// model can answer "what happened recently / did anything fail?". Uses the
/// `nonisolated` Activity display helpers from ActivityDisplay.swift.
@available(iOS 26, *)
struct RecentActivitiesTool: Tool {
    let context: ArcaneToolContext

    let name = "recentActivities"
    let description = "List the most recent activities (deployments, image pulls, prunes, scans) in the current environment with their status. Use this to find out what happened recently or whether anything failed."

    @Generable
    struct Arguments {
        @Guide(description: "If true, only return failed activities.")
        var onlyFailed: Bool?
        @Guide(description: "How many recent activities to read (5–25). Defaults to 15.")
        var limit: Int?
    }

    func call(arguments: Arguments) async throws -> String {
        context.status.report("Reviewing recent activity…")
        let cap = min(max(arguments.limit ?? 15, 5), 25)
        var items: [Activity]
        do {
            items = try await context.client.activities.listPaginated(
                envID: context.envID,
                order: .descending,
                start: 0,
                limit: 25
            ).data
        } catch {
            return "Couldn't read activities: \(error.localizedDescription)"
        }

        if arguments.onlyFailed == true {
            items = items.filter { $0.status == .failed }
        }

        let shown = items.prefix(cap)
        let formatter = RelativeDateTimeFormatter()
        let lines = shown.map { activity -> String in
            let when = formatter.localizedString(for: activity.sortTime, relativeTo: Date())
            return "- \(activity.displayTitle) — \(activity.subtitle) [\(activity.status.rawValue)] \(when)"
        }
        let header = arguments.onlyFailed == true
            ? "\(items.count) failed activit(ies) in \(context.envName)."
            : "Most recent activities in \(context.envName):"
        let body = lines.isEmpty ? "(none)" : lines.joined(separator: "\n")
        return "\(header)\n\(body)"
    }
}
