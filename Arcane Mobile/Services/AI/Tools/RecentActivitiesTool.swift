import Foundation
import Arcane
import FoundationModels

/// Recent activities (deploys, pulls, prunes, scans…), or — when activityId is
/// passed — one activity's full output log, tail-biased because failures put
/// the cause in the last lines. v2-only; not registered on v1 servers.
@available(iOS 26, *)
struct RecentActivitiesTool: Tool {
    let context: ArcaneToolContext

    let name = "recentActivities"
    let description = "Recent activities with status and id. Pass activityId for one activity's full output — use to explain failures."

    @Generable
    struct Arguments {
        @Guide(description: "Only failed activities.")
        var onlyFailed: Bool?
        @Guide(description: "How many to read (5–25).")
        var limit: Int?
        @Guide(description: "An id from a previous call → full output log.")
        var activityId: String?
    }

    func call(arguments: Arguments) async throws -> String {
        if let id = arguments.activityId?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            return await detailText(id: id)
        }
        return await listText(onlyFailed: arguments.onlyFailed == true, limit: arguments.limit)
    }

    private func listText(onlyFailed: Bool, limit: Int?) async -> String {
        context.status.report("Reviewing recent activity…")
        let cap = min(max(limit ?? 15, 5), 25)
        var items: [Activity]
        do {
            items = try await context.client.activities.listPaginated(
                envID: context.envID,
                order: .descending,
                start: 0,
                limit: 25
            ).data
        } catch {
            return ToolSupport.friendlyFailure(error, reading: "activity history")
        }

        if onlyFailed {
            items = items.filter { $0.status == .failed }
        }

        let formatter = RelativeDateTimeFormatter()
        let lines = ToolSupport.truncatedLines(items, limit: cap, itemSingular: "activity") { activity in
            let when = formatter.localizedString(for: activity.sortTime, relativeTo: Date())
            let status = activity.status.rawValue
            return ToolSupport.itemLine(
                name: ToolSupport.safeText(activity.displayTitle),
                status: status,
                reason: ToolSupport.safeText(activity.subtitle),
                next: when,
                internalId: activity.id
            )
        }
        let header = onlyFailed
            ? "\(ToolSupport.countSummary(items.count, singular: "failed activity")) in \(ToolSupport.displayName(context.envName, fallback: "environment"))."
            : "Most recent activities in \(ToolSupport.displayName(context.envName, fallback: "environment"))."
        let body = lines.isEmpty ? "(none)" : lines.joined(separator: "\n")
        return "\(header)\n\(body)"
    }

    private func detailText(id: String) async -> String {
        context.status.report("Reading activity output…")
        let detail: ActivityDetail
        do {
            detail = try await context.client.activities.detail(
                envID: context.envID,
                activityID: id,
                limit: 100
            )
        } catch {
            return ToolSupport.friendlyFailure(error, reading: "activity “\(id)”")
        }

        let a = detail.activity
        var lines: [String] = []
        lines.append(ToolSupport.itemLine(name: ToolSupport.safeText(a.displayTitle), status: a.status.rawValue, reason: ToolSupport.safeText(a.subtitle)))
        if let ms = a.durationMs { lines.append("duration: \(Double(ms) / 1000.0)s") }
        if let error = a.error, !error.isEmpty { lines.append("reason: \(ToolSupport.safeText(error))") }

        let messages = detail.messages.suffix(20)
        if messages.isEmpty {
            lines.append("(no output messages recorded)")
        } else {
            lines.append("output (most recent last):")
            for m in messages {
                lines.append("- [\(m.level.rawValue)] \(m.message)")
            }
        }
        let text = lines.joined(separator: "\n")
        // Keep the tail — that's where failure causes live.
        return text.count > 1500 ? "…" + String(text.suffix(1500)) : text
    }
}
