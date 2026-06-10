import Foundation
import Arcane
import FoundationModels

/// Lists volumes in the active environment with driver and in-use state.
@available(iOS 26, *)
struct ListVolumesTool: Tool {
    let context: ArcaneToolContext

    let name = "listVolumes"
    let description = "List Docker volumes in the current environment with their driver and whether they're in use by a container. Use this to find unused volumes or check storage."

    @Generable
    struct Arguments {
        @Guide(description: "Optional substring to match against volume names. Omit to list all.")
        var filter: String?
        @Guide(description: "If true, only return volumes not used by any container.")
        var onlyUnused: Bool?
    }

    func call(arguments: Arguments) async throws -> String {
        context.status.report("Checking volumes…")
        var items: [Volume]
        do {
            items = try await context.client.volumes.list(
                envID: context.envID,
                query: .init(start: 0, limit: 500)
            ).data
        } catch {
            return "Couldn't list volumes: \(error.localizedDescription)"
        }

        // Totals before filtering so a zero-match filter can't read as "no volumes exist".
        let total = items.count
        let unusedTotal = items.count { $0.inUse != true }
        let header = "\(total) volume(s) in \(context.envName) (\(unusedTotal) unused)."

        if let filter = arguments.filter?.trimmingCharacters(in: .whitespacesAndNewlines), !filter.isEmpty {
            items = items.filter { $0.name.localizedCaseInsensitiveContains(filter) }
        }
        if arguments.onlyUnused == true {
            items = items.filter { $0.inUse != true }
        }

        let shown = items.prefix(25)
        let lines = shown.map { volume -> String in
            let usage = volume.inUse == true ? "in use" : "unused"
            return "- \(volume.name) [\(usage)] driver=\(volume.driver)"
        }
        let more = items.count > shown.count ? "\n(+\(items.count - shown.count) more not shown)" : ""
        let body: String
        if lines.isEmpty {
            body = arguments.onlyUnused == true
                ? "(no unused volumes — all are in use)"
                : "(no volumes match that filter)"
        } else {
            body = lines.joined(separator: "\n")
        }
        return "\(header)\n\(body)\(more)"
    }
}
