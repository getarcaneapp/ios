import SwiftUI
import Arcane

struct ContainerPortsSection: View {
    let ports: [ContainerPort]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Ports", systemImage: "arrow.left.arrow.right")
            VStack(spacing: 0) {
                ForEach(Array(sortedPorts.enumerated()), id: \.offset) { index, port in
                    if index > 0 { Divider().padding(.leading, 12) }
                    portRow(port)
                        .padding(12)
                }
            }
            .dashboardCardBackground(cornerRadius: Radius.standard)

            Text("Active port mappings reported by the container.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
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
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hostDisplay(_ ip: String?) -> String {
        guard let ip, !ip.isEmpty else { return "0.0.0.0" }
        return ip
    }
}
