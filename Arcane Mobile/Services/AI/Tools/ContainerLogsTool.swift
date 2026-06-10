import Foundation
import Arcane
import FoundationModels

/// Reads the most recent log lines from a container. Hard-capped in both line
/// count and total characters, and time-bounded, so it never hangs generation
/// or overruns the context window.
@available(iOS 26, *)
struct ContainerLogsTool: Tool {
    let context: ArcaneToolContext

    let name = "getContainerLogs"
    let description = "Read the most recent log lines from a container to diagnose crashes or errors. Returns at most ~80 recent lines."

    @Generable
    struct Arguments {
        @Guide(description: "The container's id (full or short).")
        var containerId: String
        @Guide(description: "How many recent lines to read (10–80). Defaults to 60.")
        var tail: Int?
    }

    func call(arguments: Arguments) async throws -> String {
        context.status.report("Reading logs…")
        let cap = min(max(arguments.tail ?? 60, 10), 80)
        let ctx = context
        let id = arguments.containerId

        let lines = await StreamBudget.bounded { box in
            var n = 0
            do {
                for try await line in ctx.client.containers.logs(envID: ctx.envID, id: id) {
                    await box.append(line.text)
                    n += 1
                    if n >= cap { break }
                }
            } catch {
                // Partial logs are still useful; ignore stream errors.
            }
        }

        let joined = lines.suffix(cap).joined(separator: "\n")
        let clipped = joined.count > 4000 ? String(joined.suffix(4000)) : joined
        return clipped.isEmpty ? "(no recent log output)" : clipped
    }
}
