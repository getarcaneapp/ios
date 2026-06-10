import Foundation
import Arcane
import FoundationModels

/// Returns a hand-picked, compact summary of one container's config and state —
/// the diagnostic fields, never the full `ContainerDetails` payload (which would
/// blow the context window). Uses SDK-native (nonisolated) fields only.
@available(iOS 26, *)
struct InspectContainerTool: Tool {
    let context: ArcaneToolContext

    let name = "inspectContainer"
    let description = "Get key configuration and state for one container: image, command, status, exit code, health, restart policy, memory limit, ports and mounts. Use after listContainers to dig into a specific container."

    @Generable
    struct Arguments {
        @Guide(description: "The container's id (full or short) from a previous listContainers call.")
        var containerId: String
    }

    func call(arguments: Arguments) async throws -> String {
        context.status.report("Inspecting container…")
        let d: ContainerDetails
        do {
            d = try await context.client.containers.inspect(envID: context.envID, id: arguments.containerId)
        } catch {
            return "Couldn't inspect container “\(arguments.containerId)”: \(error.localizedDescription)"
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
        if !d.ports.isEmpty { lines.append("ports: \(d.ports.count) published") }
        if !d.mounts.isEmpty { lines.append("mounts: \(d.mounts.count)") }
        if let env = d.config.env, !env.isEmpty { lines.append("envVars: \(env.count)") }

        let text = lines.joined(separator: "\n")
        return String(text.prefix(3000))
    }
}
