import Foundation
import Arcane
import FoundationModels

/// One container, three views: compact config/state details (default), recent
/// log lines, or a one-shot CPU/memory sample. One tool instead of three —
/// every schema lives permanently in the model's ~4k-token context window.
@available(iOS 26, *)
struct InspectContainerTool: Tool {
    let context: ArcaneToolContext

    let name = "inspectContainer"
    let description = "ONE container's details (default), recent logs, or a CPU/memory sample."

    @Generable
    enum ContainerTopic {
        case details
        case logs
        case stats
    }

    @Generable
    struct Arguments {
        @Guide(description: "Container id from listContainers.")
        var containerId: String
        @Guide(description: "details (default), logs, or stats.")
        var topic: ContainerTopic?
        @Guide(description: "Log lines to read (10–80).")
        var tail: Int?
    }

    func call(arguments: Arguments) async throws -> String {
        switch arguments.topic ?? .details {
        case .details: return await detailsText(id: arguments.containerId)
        case .logs: return await logsText(id: arguments.containerId, tail: arguments.tail)
        case .stats: return await statsText(id: arguments.containerId)
        }
    }

    // MARK: - Details

    private func detailsText(id: String) async -> String {
        context.status.report("Inspecting container…")
        let d: ContainerDetails
        do {
            d = try await context.client.containers.inspect(envID: context.envID, id: id)
        } catch {
            return ToolSupport.friendlyFailure(error, reading: "container “\(id)”")
        }
        var lines: [String] = []

        let name = d.name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !name.isEmpty { lines.append("name: \(name)") }
        if !d.image.isEmpty { lines.append("image: \(d.image)") }
        lines.append("status: \(d.state.status)")
        lines.append("running: \(d.state.running)")
        if let exit = d.state.exitCode, !d.state.running { lines.append("exitCode: \(exit)") }
        if let health = d.state.health { lines.append("health: \(health.status) (failingStreak \(health.failingStreak))") }
        if let started = d.state.startedAt { lines.append("startedAt: \(started)") }
        if let finished = d.state.finishedAt, !d.state.running { lines.append("finishedAt: \(finished)") }
        if let policy = d.hostConfig.restartPolicy, !policy.isEmpty { lines.append("restartPolicy: \(policy)") }
        if let mode = d.hostConfig.networkMode, !mode.isEmpty { lines.append("networkMode: \(mode)") }
        if let mem = d.hostConfig.memory, mem > 0 {
            lines.append("memoryLimit: \(ByteCountFormatter.string(fromByteCount: mem, countStyle: .file))")
        }
        if let cmd = d.config.cmd, !cmd.isEmpty { lines.append("command: \(cmd.joined(separator: " "))") }
        if !d.ports.isEmpty {
            lines.append("ports:")
            for port in d.ports.prefix(8) {
                let published = port.publicPort.map { "\($0)→" } ?? ""
                lines.append("- \(published)\(port.privatePort)/\(port.type)")
            }
            if d.ports.count > 8 { lines.append("(+\(d.ports.count - 8) more ports)") }
        }
        if !d.mounts.isEmpty {
            lines.append("mounts:")
            for mount in d.mounts.prefix(8) {
                let source = mount.name ?? mount.source ?? "?"
                let mode = mount.rw == false ? " (ro)" : ""
                lines.append("- [\(mount.type)] \(source) → \(mount.destination)\(mode)")
            }
            if d.mounts.count > 8 { lines.append("(+\(d.mounts.count - 8) more mounts)") }
        }
        if let env = d.config.env, !env.isEmpty {
            lines.append("env:")
            for entry in env.prefix(10) {
                let parts = entry.split(separator: "=", maxSplits: 1)
                let key = String(parts.first ?? "")
                let value = parts.count > 1 ? String(parts[1]) : ""
                if ToolSupport.isSecretKey(key) || value.isEmpty {
                    lines.append("- \(key)=•••")
                } else {
                    lines.append("- \(key)=\(String(value.prefix(40)))")
                }
            }
            if env.count > 10 { lines.append("(+\(env.count - 10) more env vars)") }
        }

        let text = lines.joined(separator: "\n")
        return String(text.prefix(3000))
    }

    // MARK: - Logs (hard-capped in lines, chars, and time)

    private func logsText(id: String, tail: Int?) async -> String {
        context.status.report("Reading logs…")
        let cap = min(max(tail ?? 60, 10), 80)
        let ctx = context

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

    // MARK: - Stats (one frame, summarized)

    private func statsText(id: String) async -> String {
        context.status.report("Reading stats…")
        let ctx = context

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
