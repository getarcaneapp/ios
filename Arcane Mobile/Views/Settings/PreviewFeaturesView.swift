import SwiftUI

struct PreviewFeaturesView: View {
    @Environment(ArcaneClientManager.self) private var manager
    @AppStorage(ComposePreviewSession.preferenceKey) private var nativeComposeEditor = false

    @State private var showsIntroduction = false
    @State private var showsDashboardIntroduction = false

    var body: some View {
        List {
            Section {
                Toggle("Native Compose Editor", isOn: $nativeComposeEditor)
            } footer: {
                Text("Edit Compose files with native forms. YAML editing remains available.")
            }
            Section {
                Toggle(
                    "Refreshed Dashboard",
                    isOn: Binding(
                        get: { manager.refreshedDashboardPreview },
                        set: { manager.refreshedDashboardPreview = $0 }
                    ))
                Button("Replay Walkthrough") { showsDashboardIntroduction = true }
                if manager.refreshedDashboardPreview {
                    NavigationLink("Edit Tiles") { DashboardTilesEditor() }
                }
            } footer: {
                Text("Replace the dashboard's environment cards with live usage graphs, the busiest containers, and an inventory row for every host. Touch and hold the top tiles to edit them.")
            }
            Section {
                Toggle(
                    "All Environments",
                    isOn: Binding(
                        get: { manager.allEnvironmentsPreview },
                        set: { manager.allEnvironmentsPreview = $0 }
                    ))
                Button("Replay Walkthrough") { showsIntroduction = true }
                NavigationLink("Environment Colors") { EnvironmentColorsView() }
            } footer: {
                Text(
                    "Show resources from all enabled environments together. Environment switching is unavailable while this preview is on."
                )
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Preview Features")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsIntroduction) {
            AllEnvironmentsIntroductionView()
        }
        .sheet(isPresented: $showsDashboardIntroduction) {
            RefreshedDashboardIntroductionView()
        }
    }
}
