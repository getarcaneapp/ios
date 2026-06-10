import Foundation
import Arcane
import FoundationModels

/// Lists networks in the active environment with driver and scope.
@available(iOS 26, *)
struct ListNetworksTool: Tool {
    let context: ArcaneToolContext

    let name = "listNetworks"
    let description = "List Docker networks in the current environment with their driver and scope. Use this to check connectivity setup or find a network by name."

    @Generable
    struct Arguments {
        @Guide(description: "Optional substring to match against network names or driver. Omit to list all.")
        var filter: String?
    }

    func call(arguments: Arguments) async throws -> String {
        context.status.report("Checking networks…")
        var items: [NetworkSummary]
        do {
            items = try await context.client.networks.list(
                envID: context.envID,
                query: .init(start: 0, limit: 500)
            ).data
        } catch {
            return "Couldn't list networks: \(error.localizedDescription)"
        }

        if let filter = arguments.filter?.trimmingCharacters(in: .whitespacesAndNewlines), !filter.isEmpty {
            items = items.filter {
                $0.name.localizedCaseInsensitiveContains(filter)
                    || $0.driver.localizedCaseInsensitiveContains(filter)
            }
        }

        let shown = items.prefix(25)
        let lines = shown.map { network -> String in
            "- \(network.name) driver=\(network.driver) scope=\(network.scope)"
        }
        let header = "\(items.count) network(s) in \(context.envName)."
        let more = items.count > shown.count ? "\n(+\(items.count - shown.count) more not shown)" : ""
        let body = lines.isEmpty ? "(no matching networks)" : lines.joined(separator: "\n")
        return "\(header)\n\(body)\(more)"
    }
}
