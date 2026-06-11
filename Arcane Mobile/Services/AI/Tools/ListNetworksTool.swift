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
    enum NetworkTopic {
        case list
        case topology
        case inspect
        case ports
    }

    @Generable
    struct Arguments {
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

        let shown = items.prefix(25)
        let lines = shown.map { network -> String in
            "- \(network.name) driver=\(network.driver) scope=\(network.scope)"
        }
        let header = "\(items.count) network(s) in \(context.envName)."
        let more = items.count > shown.count ? "\n(+\(items.count - shown.count) more not shown)" : ""
        let body = lines.isEmpty ? "(no matching networks)" : lines.joined(separator: "\n")
        return "\(header)\n\(body)\(more)"
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
                lines.append("- \(net.name): (no containers)")
            } else {
                let shown = attached.prefix(8).joined(separator: ", ")
                let more = attached.count > 8 ? " (+\(attached.count - 8) more)" : ""
                lines.append("- \(net.name): \(shown)\(more)")
            }
        }
        if networks.count > 20 { lines.append("(+\(networks.count - 20) more networks)") }
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
        lines.append("network: \(n.name)")
        lines.append("driver: \(n.driver), scope: \(n.scope)")
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

        let shown = items.prefix(25)
        var lines = ["\(total) port mapping(s) in \(context.envName)."]
        if shown.isEmpty {
            lines.append("(no ports match that filter)")
        }
        for p in shown {
            let host = p.hostPort.map { "\($0)→" } ?? "(internal) "
            lines.append("- \(host)\(p.containerPort)/\(p.protocolName) \(p.containerName)")
        }
        if items.count > shown.count { lines.append("(+\(items.count - shown.count) more not shown)") }
        return lines.joined(separator: "\n")
    }
}
