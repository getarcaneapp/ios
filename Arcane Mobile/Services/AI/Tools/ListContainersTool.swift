import Foundation
import Arcane
import FoundationModels

/// Lists containers in the active environment. Bounded to a compact set of
/// rows so the model gets an overview without exhausting the context window.
/// Uses only SDK-native (nonisolated) fields — the app's `displayName`/`isRunning`
/// extensions are main-actor-isolated and can't be touched from a tool's `call`.
@available(iOS 26, *)
struct ListContainersTool: Tool {
    let context: ArcaneToolContext

    let name = "listContainers"
    let description = "List containers with status and image. Use first for running/up/down/container questions."

    @Generable
    struct Arguments {
        @Guide(description: "Name/image substring filter.")
        var filter: String?
        @Guide(description: "Only non-running containers.")
        var onlyProblematic: Bool?
    }

    func call(arguments: Arguments) async throws -> String {
        context.status.report("Checking containers…")
        var items: [ContainerSummary]
        do {
            // Raw REST path + lenient decode, exactly like ContainersView.
            // The typed `client.containers.list` endpoint doesn't match the
            // current server's response shape and fails — the containers page
            // deliberately avoids it for the same reason.
            let path = context.client.rest.environmentPath(context.envID, "containers")
            let wrapped: LenientArray<ContainerSummary> = try await context.client.rest.get(path)
            items = wrapped.elements
        } catch {
            return ToolSupport.friendlyFailure(error, reading: "containers")
        }

        // Totals BEFORE any filtering — the header must always reflect the real
        // environment state, or "onlyProblematic with zero matches" reads to the
        // model as "zero containers exist".
        let total = items.count
        let runningTotal = items.count { $0.state.lowercased() == "running" }
        let stoppedTotal = total - runningTotal
        let header = """
        \(ToolSupport.countSummary(total, singular: "container")) in \(context.envName): \
        \(ToolSupport.countSummary(runningTotal, singular: "running container")), \
        \(ToolSupport.countSummary(stoppedTotal, singular: "stopped container")).
        """.trimmingCharacters(in: .whitespacesAndNewlines)

        if let filter = arguments.filter?.trimmingCharacters(in: .whitespacesAndNewlines), !filter.isEmpty {
            items = items.filter { c in
                c.names.contains { $0.localizedCaseInsensitiveContains(filter) }
                    || c.image.localizedCaseInsensitiveContains(filter)
            }
        }
        if arguments.onlyProblematic == true {
            items = items.filter { $0.state.lowercased() != "running" }
        }

        let lines = ToolSupport.truncatedLines(items, limit: 25, itemSingular: "container") { c -> String in
            let raw = c.names.first ?? ""
            let name = ToolSupport.displayName(raw)
            let status = ToolSupport.safeText(c.state)
            let health = status.lowercased() == "running" ? "healthy" : "unhealthy"
            let reason = status.lowercased() == "running" ? nil : ToolSupport.safeText(status)
            let displayName = raw.isEmpty ? String(c.id.prefix(12)) : raw
            return ToolSupport.itemLine(
                name: name.isEmpty ? displayName : name,
                status: status,
                reason: reason,
                image: ToolSupport.safeText(c.image),
                health: health,
                internalId: c.id
            )
        }
        let body: String
        if lines.isEmpty {
            body = arguments.onlyProblematic == true
                ? "(no stopped containers in \(ToolSupport.displayName(context.envName, fallback: "environment")) — every container is running)"
                : "(no matching containers found in \(ToolSupport.displayName(context.envName, fallback: "environment")))"
        }
        else {
            body = lines.joined(separator: "\n")
        }
        return "\(header)\n\(body)"
    }
}
