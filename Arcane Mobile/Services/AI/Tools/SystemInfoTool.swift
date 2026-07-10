import Foundation
import Arcane
import FoundationModels

/// Reads Docker host info (version, OS, counts, memory) for the active
/// environment. Reads the raw `info` map directly — the typed convenience
/// accessors in Models.swift are main-actor-isolated and unavailable here.
@available(iOS 26, *)
struct SystemInfoTool: Tool {
    let context: ArcaneToolContext

    let name = "systemInfo"
    let description = "Docker host info: versions, OS, counts, memory, Swarm. includeLiveStats samples live CPU/memory."

    @Generable
    struct Arguments: Sendable {
        @Guide(description: "Also sample live CPU/memory/disk.")
        var includeLiveStats: Bool?
    }

    func call(arguments: Arguments) async throws -> String {
        context.status.report("Reading host info…")
        let path = context.client.rest.environmentPath(context.envID, "system/docker/info")
        let dockerInfo: DockerInfo
        do {
            let rawData = try await context.client.transport.rawRequest(path, body: Optional<String>.none)
            dockerInfo = try JSONDecoder().decode(DockerInfo.self, from: rawData)
        } catch {
            return ToolSupport.friendlyFailure(error, reading: "host info")
        }

        let info = dockerInfo.info
        func str(_ key: String) -> String { info?[key]?.stringValue ?? "unknown" }
        func num(_ key: String) -> Int64 { info?[key]?.int64Value ?? 0 }

        var lines: [String] = []
        lines.append("Docker \(str("ServerVersion")) on \(str("OperatingSystem")) (\(str("OSType"))/\(str("Architecture")))")
        lines.append("Containers: \(num("Containers")) total — \(num("ContainersRunning")) running, \(num("ContainersPaused")) paused, \(num("ContainersStopped")) stopped")
        lines.append("Images: \(num("Images"))")
        let memBytes = num("MemTotal")
        if memBytes > 0 {
            lines.append("Memory: \(ByteCountFormatter().string(fromByteCount: memBytes))")
        }
        lines.append("CPUs: \(num("NCPU"))")

        // Everything below is best-effort garnish — never fail the primary answer.
        if let version = try? await context.client.version.environmentVersion(envID: context.envID) {
            var line = "Arcane server: \(version.displayVersion)"
            if let upgrade = try? await context.client.system.checkUpgrade(envID: context.envID),
               upgrade.canUpgrade, !upgrade.error {
                line += " — upgrade available (\(upgrade.message))"
            }
            lines.append(line)
        }
        if let swarm = try? await context.client.swarm.status(envID: context.envID) {
            lines.append("Swarm: \(swarm.enabled ? "active" : "inactive")")
        }
        if arguments.includeLiveStats == true {
            context.status.report("Sampling live stats…")
            let ctx = context
            let samples = await StreamBudget.bounded(timeout: .seconds(4)) { box in
                do {
                    for try await stats in ctx.client.system.statsStream(envID: ctx.envID) {
                        let cpu = String(format: "%.1f%%", stats.cpuUsage)
                        let mem = ByteCountFormatter.string(fromByteCount: Int64(stats.memoryUsage), countStyle: .file)
                        let memTotal = ByteCountFormatter.string(fromByteCount: Int64(stats.memoryTotal), countStyle: .file)
                        var line = "Live: cpu \(cpu), mem \(mem)/\(memTotal)"
                        if let used = stats.diskUsage, let total = stats.diskTotal, total > 0 {
                            let disk = ByteCountFormatter.string(fromByteCount: Int64(used), countStyle: .file)
                            let diskTotal = ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
                            line += ", disk \(disk)/\(diskTotal)"
                        }
                        await box.append(line)
                        break   // one sample is enough
                    }
                } catch {
                    // ignore — stats are optional garnish
                }
            }
            if let sample = samples.first { lines.append(sample) }
        }
        return "Host info for \(context.envName):\n" + lines.joined(separator: "\n")
    }
}
