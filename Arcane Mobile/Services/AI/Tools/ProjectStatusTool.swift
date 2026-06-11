import Foundation
import Arcane
import FoundationModels

/// One project, three views: per-service status (default), the compose file
/// content, or recent project logs. The topic enum keeps this a single tool —
/// the on-device model's tool budget is tight.
@available(iOS 26, *)
struct ProjectStatusTool: Tool {
    let context: ArcaneToolContext

    let name = "getProjectStatus"
    let description = "ONE project's per-service status (default), compose file, or recent logs."

    @Generable
    enum ProjectTopic {
        case status
        case compose
        case logs
    }

    @Generable
    struct Arguments {
        @Guide(description: "Project id or name from listProjects.")
        var project: String
        @Guide(description: "status (default), compose, or logs.")
        var topic: ProjectTopic?
    }

    func call(arguments: Arguments) async throws -> String {
        context.status.report("Checking project status…")
        // Resolve id-or-name through the list — same recipe as before, and it
        // gives the model a clean miss message instead of a server 404.
        let items: [ProjectDetails]
        do {
            items = try await context.client.projects.list(
                envID: context.envID,
                query: SearchPaginationSort(start: 0, limit: 200)
            ).data
        } catch {
            return ToolSupport.friendlyFailure(error, reading: "project status")
        }
        let needle = arguments.project.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let p = items.first(where: {
            $0.id == needle || $0.name.localizedCaseInsensitiveCompare(needle) == .orderedSame
        }) else {
            return "No project matching “\(needle)”. Call listProjects to see available projects."
        }

        switch arguments.topic ?? .status {
        case .status: return await statusText(for: p)
        case .compose: return await composeText(for: p)
        case .logs: return await logsText(for: p)
        }
    }

    private func statusText(for p: ProjectDetails) async -> String {
        var lines = ["\(p.name): status \(p.status), \(p.runningCount)/\(p.serviceCount) services running."]
        // Per-service runtime detail is best-effort garnish — never fail the answer for it.
        if let runtime = try? await context.client.projects.runtime(envID: context.envID, projectID: p.id),
           let services = runtime.runtimeServices, !services.isEmpty {
            for s in services.prefix(15) {
                let health = s.health.map { " health=\($0)" } ?? ""
                lines.append("- \(s.name) [\(s.status)]\(health) image=\(s.image)")
            }
            if services.count > 15 { lines.append("(+\(services.count - 15) more services)") }
        }
        return lines.joined(separator: "\n")
    }

    private func composeText(for p: ProjectDetails) async -> String {
        let detail: ProjectDetails
        do {
            detail = try await context.client.projects.compose(envID: context.envID, projectID: p.id)
        } catch {
            return ToolSupport.friendlyFailure(error, reading: "compose file for “\(p.name)”")
        }
        guard let content = detail.composeContent, !content.isEmpty else {
            return "(no compose file content available for “\(p.name)”)"
        }
        let clipped = content.count > 3000 ? String(content.prefix(3000)) + "\n(truncated)" : content
        return "\(detail.composeFileName ?? "compose.yaml") for \(p.name):\n\(clipped)"
    }

    private func logsText(for p: ProjectDetails) async -> String {
        context.status.report("Reading project logs…")
        let ctx = context
        let id = p.id
        let lines = await StreamBudget.bounded { box in
            var n = 0
            do {
                for try await line in ctx.client.projects.logs(envID: ctx.envID, projectID: id, tail: "60") {
                    await box.append(line.text)
                    n += 1
                    if n >= 60 { break }
                }
            } catch {
                // Partial logs are still useful; ignore stream errors.
            }
        }
        let joined = lines.suffix(60).joined(separator: "\n")
        let clipped = joined.count > 4000 ? String(joined.suffix(4000)) : joined
        return clipped.isEmpty ? "(no recent log output for “\(p.name)”)" : clipped
    }
}
