import SwiftUI

/// Placeholder for the Swarm tab while the management UI is being reworked.
/// The tab stays in the navigation; the functional cluster/services/nodes
/// screens are temporarily removed.
struct SwarmView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Swarm", systemImage: "square.stack.3d.up")
        } description: {
            Text("Swarm management is coming soon.")
        }
        .navigationTitle("Swarm")
    }
}
