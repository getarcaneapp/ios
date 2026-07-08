import SwiftUI
import Arcane

struct ContainerPortsSection: View {
    let ports: [ContainerPort]

    var body: some View {
        Section {
            ForEach(Array(sortedPorts.enumerated()), id: \.offset) { _, port in
                portRow(port)
            }
        } header: {
            Text("Ports")
        } footer: {
            Text("Active port mappings reported by the container.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var sortedPorts: [ContainerPort] {
        ports.sorted { lhs, rhs in
            if lhs.privatePort != rhs.privatePort { return lhs.privatePort < rhs.privatePort }
            return lhs.type < rhs.type
        }
    }

    @ViewBuilder
    private func portRow(_ port: ContainerPort) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if let publicPort = port.publicPort {
                    Text(verbatim: "\(hostDisplay(port.ip)):\(publicPort)")
                        .font(.system(.body, design: .monospaced))
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(verbatim: "\(port.privatePort)/\(port.type)")
                    .font(.system(.body, design: .monospaced))
                Spacer()
                if port.publicPort == nil {
                    Text("internal")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 2)
                        .padding(.horizontal, 6)
                        .background(.regularMaterial, in: .capsule)
                }
            }
        }
    }

    private func hostDisplay(_ ip: String?) -> String {
        guard let ip, !ip.isEmpty else { return "0.0.0.0" }
        return ip
    }
}
