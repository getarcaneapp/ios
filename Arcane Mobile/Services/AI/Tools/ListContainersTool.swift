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
    let description = "List containers in the current environment with their status (running/exited/paused) and image. Use this to find a container by name or to get an overview before diagnosing."

    @Generable
    struct Arguments {
        @Guide(description: "Optional substring to match against container names or image. Omit to list all.")
        var filter: String?
        @Guide(description: "If true, only return containers that are not running (exited, dead, restarting).")
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
            return "Couldn't list containers: \(error.localizedDescription)"
        }

        // Totals BEFORE any filtering — the header must always reflect the real
        // environment state, or "onlyProblematic with zero matches" reads to the
        // model as "zero containers exist".
        let total = items.count
        let runningTotal = items.count { $0.state.lowercased() == "running" }
        let header = "\(total) container(s) in \(context.envName): \(runningTotal) running, \(total - runningTotal) not running."

        if let filter = arguments.filter?.trimmingCharacters(in: .whitespacesAndNewlines), !filter.isEmpty {
            items = items.filter { c in
                c.names.contains { $0.localizedCaseInsensitiveContains(filter) }
                    || c.image.localizedCaseInsensitiveContains(filter)
            }
        }
        if arguments.onlyProblematic == true {
            items = items.filter { $0.state.lowercased() != "running" }
        }

        let shown = items.prefix(25)
        let lines = shown.map { c -> String in
            let raw = c.names.first?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
            let displayName = raw.isEmpty ? String(c.id.prefix(12)) : raw
            return "- \(displayName) [\(c.state)] image=\(c.image) id=\(String(c.id.prefix(12)))"
        }
        let more = items.count > shown.count ? "\n(+\(items.count - shown.count) more not shown)" : ""
        let body: String
        if lines.isEmpty {
            body = arguments.onlyProblematic == true
                ? "(no problematic containers — every container is running)"
                : "(no containers match that filter)"
        } else {
            body = lines.joined(separator: "\n")
        }
        return "\(header)\n\(body)\(more)"
    }
}
