import SwiftUI
import Arcane

struct UpdatesView: View {
    let environmentID: EnvironmentID

    var body: some View {
        List {
            Section {
                NavigationLink {
                    ImageUpdatesView(environmentID: environmentID, images: [])
                } label: {
                    Label("Image Updates", systemImage: "photo.stack")
                }
                DynamicNavigationRow(
                    title: "Updater History",
                    subtitle: "Recent update runs",
                    systemImage: "clock.arrow.circlepath"
                ) {
                    UpdaterHistoryView(environmentID: environmentID)
                }
            }
            Section("Actions") {
                NavigationLink {
                    UpdaterRunView(environmentID: environmentID)
                } label: {
                    Label("Run Updater", systemImage: "play.circle.fill")
                }
                RunEndpointButton(
                    title: "Check All Image Updates",
                    systemImage: "arrow.clockwise.circle",
                    path: { client in client.rest.environmentPath(environmentID, "image-updates/check-all") }
                )
            }
        }
        .navigationTitle("Updates")
    }
}
