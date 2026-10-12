import Arcane
import SwiftUI

extension EnvironmentValues {
    @Entry var rowEnvironmentID: String? = nil
}

struct EnvironmentLabel: View {
    let name: String?
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.rowEnvironmentID) private var environmentID
    @State private var colors = EnvironmentColorStore.shared

    private var color: Color {
        guard manager.allEnvironmentsPreview, let environmentID,
            let hex = colors.hex(server: manager.serverURL, environmentID: environmentID)
        else { return .secondary }
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

extension View {
    /// Colors a row's `EnvironmentLabel` for an All Environments list item.
    func rowEnvironment<Value>(_ item: EnvironmentItem<Value>) -> some View {
        environment(\.rowEnvironmentID, item.environmentName == nil ? nil : item.environmentID.rawValue)
    }
}

/// Environment section for a list's filter sheet. Only shown in All Environments lists.
struct EnvironmentFilterSection: View {
    let environments: [ListEnvironment]
    @Binding var selection: EnvironmentID?

    var body: some View {
        if environments.contains(where: { $0.name != nil }) {
            Section("Environment") {
                Picker("Environment", selection: $selection) {
                    Text("All Environments").tag(EnvironmentID?.none)
                    ForEach(environments, id: \.id) { environment in
                        Text(environment.name ?? environment.id.rawValue).tag(EnvironmentID?.some(environment.id))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
    }
}

/// Rows for environments that failed to load while others succeeded.
struct EnvironmentLoadFailuresSection: View {
    let failures: [EnvironmentLoadFailure]
    let retry: () -> Void

    var body: some View {
        if !failures.isEmpty {
            Section {
                ForEach(failures) { failure in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(
                            "Couldn't load \(failure.environment.name ?? failure.environment.id.rawValue)",
                            systemImage: "exclamationmark.triangle"
                        )
                        Text(failure.message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Button("Retry", action: retry)
            }
        }
    }
}

/// A toolbar-menu action that targets one environment. In All Environments
/// lists it becomes a submenu so the user picks the environment.
struct EnvironmentActionButton: View {
    let title: String
    let systemImage: String
    let environments: [ListEnvironment]
    let action: (EnvironmentID) -> Void

    var body: some View {
        if environments.count > 1 || environments.first?.name != nil {
            Menu {
                ForEach(environments, id: \.id) { environment in
                    Button(environment.name ?? environment.id.rawValue) { action(environment.id) }
                }
            } label: {
                Label(title, systemImage: systemImage)
            }
        } else if let environment = environments.first {
            Button(title, systemImage: systemImage) { action(environment.id) }
        }
    }
}
