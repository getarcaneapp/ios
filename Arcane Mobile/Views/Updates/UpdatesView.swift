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
                    title: "Updater Status",
                    subtitle: "Automatic update worker status",
                    systemImage: "arrow.triangle.2.circlepath"
                ) {
                    UpdaterStatusView(environmentID: environmentID)
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
                RunEndpointButton(
                    title: "Run Updater",
                    systemImage: "play.circle.fill",
                    path: { client in client.rest.environmentPath(environmentID, "updater/run") }
                )
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
