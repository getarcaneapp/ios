import SwiftUI

struct AllEnvironmentsIntroductionView: View {
    @Environment(ArcaneClientManager.self) private var manager

    var body: some View {
        PreviewWalkthrough(
            pages: [
                .init(
                    title: "All your environments.\nOne view.",
                    message:
                        "See containers, projects, images and more from all enabled environments together. Your dashboard brings their totals into one place."
                ),
                .init(
                    title: "Know what belongs where.",
                    message:
                        "Environment names and colors identify every resource. Use filters to focus on one environment without leaving the list."
                ),
                .init(
                    title: "Manage them together.",
                    message:
                        "Update checks, updates and pruning apply to all enabled environments, even when a list is filtered. Review the confirmation before running an action."
                ),
            ],
            seenKey: AllEnvironmentsIntroduction.seenKey,
            footnote:
                "Optional preview. Turn it off anytime in More → Preview Features. Environment switching is hidden while it’s on.",
            isEnabled: manager.allEnvironmentsPreview,
            enable: { manager.allEnvironmentsPreview = true },
            illustration: illustration
        )
    }

    @ViewBuilder
    private func illustration(_ index: Int) -> some View {
        if index == 0 {
            Label("All Environments", systemImage: "server.rack")
                .font(.headline)
            sampleResource("Website", environment: "Production", color: .blue, icon: "cube.box.fill")
            Divider()
            sampleResource("API", environment: "Staging", color: .purple, icon: "cube.box.fill")
            Divider()
            sampleResource("Database", environment: "Home", color: .teal, icon: "cube.box.fill")
        } else if index == 1 {
            HStack {
                Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                Spacer()
                Text("Production").foregroundStyle(.blue)
            }
            .font(.subheadline.weight(.medium))
            Divider()
            sampleResource("Website", environment: "Production", color: .blue, icon: "cube.box.fill")
            sampleResource("Worker", environment: "Production", color: .blue, icon: "cube.box.fill")
        } else {
            Label("Check All", systemImage: "arrow.clockwise")
            Label("Update All", systemImage: "arrow.triangle.2.circlepath")
            DestructiveLabel(text: "Prune")
            Divider()
            Text("Across all enabled environments")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Image(systemName: "server.rack").foregroundStyle(.blue)
                Image(systemName: "server.rack").foregroundStyle(.purple)
                Image(systemName: "server.rack").foregroundStyle(.teal)
            }
        }
    }

    private func sampleResource(_ name: String, environment: String, color: Color, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.headline)
                HStack(spacing: 4) {
                    Image(systemName: "server.rack")
                    Text(environment)
                }
                .font(.caption)
                .foregroundStyle(color)
            }
        }
    }
}
