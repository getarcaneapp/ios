import SwiftUI
import Arcane

/// Swarm management is temporarily a placeholder while the screen is reworked
/// (see ReleaseNotes 0.1.9). The tab stays in navigation; the prior cluster
/// + services + nodes implementation is archived in git history and will return
/// in a future update.
struct SwarmView: View {
    let environmentID: EnvironmentID
    let environmentName: String

    init(environmentID: EnvironmentID = .localDocker, environmentName: String = "Local Docker") {
        self.environmentID = environmentID
        self.environmentName = environmentName
    }

    var body: some View {
        ContentUnavailableView {
            Label("Coming Soon", systemImage: "square.stack.3d.up")
        } description: {
            Text("Swarm management is planned for a future Arcane Mobile update.")
        }
        .navigationTitle("Swarm")
    }
}
