import SwiftUI
import Arcane

struct MainTabView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @State private var selectedTab: Int = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Dashboard", systemImage: "chart.bar.fill", value: 0) {
                DashboardView(selectedTab: $selectedTab)
            }
            Tab("Containers", systemImage: "cube.box.fill", value: 1) {
                NavigationStack {
                    ContainersView(
                        environmentID: manager.activeEnvironmentID,
                        environmentName: manager.activeEnvironmentName
                    )
                }
            }
            Tab("Images", systemImage: "photo.stack.fill", value: 2) {
                NavigationStack {
                    ImagesView(
                        environmentID: manager.activeEnvironmentID,
                        environmentName: manager.activeEnvironmentName
                    )
                }
            }
            Tab("Projects", systemImage: "square.stack.3d.up.fill", value: 3) {
                NavigationStack {
                    ProjectsView(
                        environmentID: manager.activeEnvironmentID,
                        environmentName: manager.activeEnvironmentName
                    )
                }
            }
            Tab("Settings", systemImage: "gearshape.fill", value: 4) {
                SettingsView()
            }
        }
    }
}
