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
    let description = "Read Docker host information for the current environment: Docker version, operating system, container/image counts, and total memory. Use this for questions about the host itself."

    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        context.status.report("Reading host info…")
        let path = context.client.rest.environmentPath(context.envID, "system/docker/info")
        let dockerInfo: DockerInfo
        do {
            let rawData = try await context.client.transport.rawRequest(path, body: Optional<String>.none)
            dockerInfo = try JSONDecoder().decode(DockerInfo.self, from: rawData)
        } catch {
            return "Couldn't read host info: \(error.localizedDescription)"
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
        return "Host info for \(context.envName):\n" + lines.joined(separator: "\n")
    }
}
