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
        var items: [ContainerSummary]
        do {
            items = try await context.client.containers.list(
                envID: context.envID,
                query: SearchPaginationSort(start: 0, limit: 500)
            ).data
        } catch {
            return "Couldn't list containers: \(error.localizedDescription)"
        }

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
        let header = "\(items.count) container(s) in \(context.envName)."
        let more = items.count > shown.count ? "\n(+\(items.count - shown.count) more not shown)" : ""
        let body = lines.isEmpty ? "(no matching containers)" : lines.joined(separator: "\n")
        return "\(header)\n\(body)\(more)"
    }
}
