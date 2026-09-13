import SwiftUI
import Arcane

struct ContainerPortsSection: View {
    let ports: [ContainerPort]
    private let sortedPorts: [ContainerPort]

    init(ports: [ContainerPort]) {
        self.ports = ports
        sortedPorts = ports.sorted { lhs, rhs in
            if lhs.privatePort != rhs.privatePort { return lhs.privatePort < rhs.privatePort }
            return lhs.type < rhs.type
        }
    }

    var body: some View {
        Section {
            ForEach(Array(sortedPorts.enumerated()), id: \.offset) { _, port in
                LabeledContent {
                    if let publicPort = port.publicPort {
                        Text(verbatim: "\(hostDisplay(port.ip)):\(publicPort)")
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                    } else {
                        Text("Internal").foregroundStyle(.secondary)
                    }
                } label: {
                    Text(verbatim: "\(port.privatePort)/\(port.type)")
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("Ports")
        } footer: {
            Text("Active port mappings reported by the container.")
        }
    }

    private func hostDisplay(_ ip: String?) -> String {
        guard let ip, !ip.isEmpty else { return "0.0.0.0" }
        return ip
    }
}
