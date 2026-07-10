import Foundation
import Arcane
import FoundationModels

/// Networks in four views: the list (default), the network→container topology,
/// one network's details, or published host ports ("what is using port N").
@available(iOS 26, *)
struct ListNetworksTool: Tool {
    let context: ArcaneToolContext

    let name = "listNetworks"
    let description = "List networks, the network→container topology, inspect ONE network, or list published host ports."

    @Generable
    enum NetworkTopic: Sendable {
        case list
        case topology
        case inspect
        case ports
    }

    @Generable
    struct Arguments: Sendable {
        @Guide(description: "list (default), topology, inspect, or ports.")
        var topic: NetworkTopic?
        @Guide(description: "Network name for inspect; filter for list/ports.")
        var name: String?
    }

    func call(arguments: Arguments) async throws -> String {
        context.status.report("Checking networks…")
        let name = arguments.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch arguments.topic ?? .list {
        case .list: return await listText(filter: name)
        case .topology: return await topologyText()
        case .inspect: return await inspectText(name: name)
        case .ports: return await portsText(filter: name)
        }
    }

    private func listText(filter: String) async -> String {
        var items: [NetworkSummary]
        do {
            items = try await context.client.networks.list(
                envID: context.envID,
                query: .init(start: 0, limit: 500)
            ).data
        } catch {
            return ToolSupport.friendlyFailure(error, reading: "networks")
        }

        if !filter.isEmpty {
            items = items.filter {
                $0.name.localizedCaseInsensitiveContains(filter)
                    || $0.driver.localizedCaseInsensitiveContains(filter)
            }
        }

        let lines = ToolSupport.truncatedLines(items, limit: 25, itemSingular: "network") { network in
            return ToolSupport.itemLine(
                name: ToolSupport.displayName(network.name),
                status: ToolSupport.safeText(network.scope),
                reason: ToolSupport.safeText(network.driver),
                next: "inspect for container list",
                internalId: network.id
            )
        }
        let header = "\(ToolSupport.countSummary(items.count, singular: "network")) in \(context.envName)."
        let body = lines.isEmpty ? "(no matching networks found in \(ToolSupport.displayName(context.envName, fallback: "environment")))" : lines.joined(separator: "\n")
        return "\(header)\n\(body)"
    }

    private func topologyText() async -> String {
        let topology: NetworkTopology
        do {
            topology = try await context.client.networks.topology(envID: context.envID)
        } catch {
            return ToolSupport.friendlyFailure(error, reading: "the network topology")
        }
        let names = Dictionary(uniqueKeysWithValues: topology.nodes.map { ($0.id, $0.name) })
        let networks = topology.nodes.filter { $0.type == .network }
        var lines = ["Network topology of \(context.envName):"]
        for net in networks.prefix(20) {
            let attached = topology.edges
                .filter { $0.source == net.id }
                .compactMap { names[$0.target] }
            if attached.isEmpty {
                lines.append(ToolSupport.itemLine(name: ToolSupport.safeText(net.name), status: "no containers", reason: "topology"))
            } else {
                let shown = attached.prefix(8).joined(separator: ", ")
                let more = attached.count > 8 ? " (+\(attached.count - 8) more)" : ""
                lines.append(ToolSupport.itemLine(name: ToolSupport.safeText(net.name), status: "connected", reason: shown, health: "topology", next: more.isEmpty ? nil : more.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
        if networks.count > 20 {
            lines.append("next: +\(ToolSupport.countSummary(networks.count - 20, singular: "network")) not shown")
        }
        return lines.joined(separator: "\n")
    }

    private func inspectText(name: String) async -> String {
        guard !name.isEmpty else {
            return "Pass the network's name to inspect it. Call listNetworks first if unsure."
        }
        // Resolve name → id through the list; inspect wants an id.
        let items: [NetworkSummary]
        do {
            items = try await context.client.networks.list(
                envID: context.envID,
                query: .init(start: 0, limit: 500)
            ).data
        } catch {
            return ToolSupport.friendlyFailure(error, reading: "networks")
        }
        guard let match = items.first(where: {
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame || $0.id == name
        }) else {
            return "No network matching “\(name)”. Call listNetworks to see available networks."
        }
        let n: NetworkInspect
        do {
            n = try await context.client.networks.inspect(envID: context.envID, networkID: match.id)
        } catch {
            return ToolSupport.friendlyFailure(error, reading: "network “\(name)”")
        }
        var lines: [String] = []
        lines.append(ToolSupport.itemLine(name: ToolSupport.safeText(n.name), status: ToolSupport.safeText(n.scope), reason: ToolSupport.safeText(n.driver)))
        lines.append("driver: \(ToolSupport.safeText(n.driver)), scope: \(ToolSupport.safeText(n.scope))")
        if let config = n.ipam.config?.first {
            if let subnet = config.subnet { lines.append("subnet: \(subnet)") }
            if let gateway = config.gateway { lines.append("gateway: \(gateway)") }
        }
        if n.`internal` { lines.append("internal: yes") }
        if n.attachable { lines.append("attachable: yes") }
        lines.append("containers attached: \(n.containers.count)")
        return lines.joined(separator: "\n")
    }

    private func portsText(filter: String) async -> String {
        context.status.report("Checking ports…")
        var items: [PortMapping]
        do {
            items = try await context.client.ports.list(
                envID: context.envID,
                query: SearchPaginationSort(start: 0, limit: 200)
            ).data
        } catch {
            return ToolSupport.friendlyFailure(error, reading: "ports")
        }

        let total = items.count
        if !filter.isEmpty {
            items = items.filter { p in
                p.containerName.localizedCaseInsensitiveContains(filter)
                    || p.hostPort.map { String($0) == filter } == true
                    || String(p.containerPort) == filter
            }
        }

        let header = "\(ToolSupport.countSummary(total, singular: "port mapping")) in \(context.envName)."
        let lines = ToolSupport.truncatedLines(items, limit: 25, itemSingular: "port mapping") { p in
            let host = p.hostPort.map { String($0) } ?? "internal"
            let reason = "\(host) → \(p.containerPort)/\(p.protocolName) \(ToolSupport.safeText(p.containerName))"
            return ToolSupport.itemLine(name: ToolSupport.safeText(p.containerName), status: "mapped", reason: reason, next: p.hostPort == nil ? "internal" : host)
        }
        if lines.isEmpty { return "\(header)\n(no ports match that filter)" }
        return "\(header)\n\(lines.joined(separator: "\n"))"
    }
}
