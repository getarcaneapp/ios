import SwiftUI

struct PreviewFeaturesView: View {
    @Environment(ArcaneClientManager.self) private var manager
    @AppStorage(ComposePreviewSession.preferenceKey) private var nativeComposeEditor = false

    @State private var showsIntroduction = false

    var body: some View {
        List {
            Section {
                Toggle("Native Compose Editor", isOn: $nativeComposeEditor)
            } footer: {
                Text("Edit Compose files with native forms. YAML editing remains available.")
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
    }
}
