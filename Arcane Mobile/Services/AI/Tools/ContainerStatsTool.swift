import Foundation
import Arcane
import FoundationModels

/// Takes a single CPU/memory sample for a running container. Does not stream
/// into the model — one frame from the stats stream, summarized.
@available(iOS 26, *)
struct ContainerStatsTool: Tool {
    let context: ArcaneToolContext

    let name = "getContainerStats"
    let description = "Get a one-shot CPU and memory usage sample for a running container."

    @Generable
    struct Arguments {
        @Guide(description: "The container's id (full or short). The container must be running.")
        var containerId: String
    }

    func call(arguments: Arguments) async throws -> String {
        let ctx = context
        let id = arguments.containerId

        let samples = await StreamBudget.bounded(timeout: .seconds(4)) { box in
            do {
                for try await frame in ctx.client.containers.stats(envID: ctx.envID, id: id) {
                    let s = frame.currentHistorySample
                    let cpu = String(format: "%.1f%%", Double(s.cpuTenths) / 10.0)
                    let memPct = String(format: "%.1f%%", Double(s.memoryTenths) / 10.0)
                    let mem = ByteCountFormatter.string(fromByteCount: Int64(s.memoryUsageBytes), countStyle: .file)
                    await box.append("cpu \(cpu), mem \(mem) (\(memPct))")
                    break   // one sample is enough
                }
            } catch {
                // ignore — likely not running
            }
        }

        return samples.first ?? "(no stats available — the container may not be running)"
    }
}
