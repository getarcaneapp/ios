import SwiftUI

private struct FleetEnvironmentIDKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var fleetEnvironmentID: String? {
        get { self[FleetEnvironmentIDKey.self] }
        set { self[FleetEnvironmentIDKey.self] = newValue }
    }
}

struct FleetEnvironmentLabel: View {
    let name: String?
    @Environment(ArcaneClientManager.self) private var manager
    @Environment(\.fleetEnvironmentID) private var environmentID
    @State private var colors = EnvironmentColorStore.shared

    private var color: Color {
        guard manager.allEnvironmentsPreview, let environmentID,
              let hex = colors.hex(server: manager.serverURL, environmentID: environmentID) else { return .secondary }
        return Color(hex: hex) ?? .secondary
    }

    var body: some View {
        if let name {
            HStack(spacing: 4) {
                Image(systemName: "server.rack").accessibilityHidden(true)
                Text(name)
            }
            .font(.caption)
            .foregroundStyle(color)
        }
    }
}
