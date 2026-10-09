import SwiftUI

struct AllEnvironmentsIntroductionView: View {
    @Environment(ArcaneClientManager.self) private var manager
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AllEnvironmentsIntroduction.seenKey) private var hasSeenIntroduction = false
    @State private var page = 0

    var body: some View {
        NavigationStack {
            TabView(selection: $page) {
                introductionPage(
                    title: "All your environments.\nOne view.",
                    message: "See containers, projects, images and more from all enabled environments together. Your dashboard brings their totals into one place.",
                    illustration: 0
                ).tag(0)
                introductionPage(
                    title: "Know what belongs where.",
                    message: "Environment names and colors identify every resource. Use filters to focus on one environment without leaving the list.",
                    illustration: 1
                ).tag(1)
                introductionPage(
                    title: "Manage them together.",
                    message: "Update checks, updates and pruning apply to all enabled environments, even when a list is filtered. Review the confirmation before running an action.",
                    illustration: 2
                ).tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            // Keep the pager's viewport constant throughout interactive swipes.
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 12) {
                    HStack(spacing: 8) {
                        ForEach(0..<3) { index in
                            Circle()
                                .fill(index == page ? Color.accentColor : Color.secondary.opacity(0.25))
                                .frame(width: 7, height: 7)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Page \(page + 1) of 3")
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: page = min(page + 1, 2)
                        case .decrement: page = max(page - 1, 0)
                        @unknown default: break
                        }
                    }

                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .background(.background)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { finish() }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .onDisappear { hasSeenIntroduction = true }
    }

    private func finish() {
        hasSeenIntroduction = true
        dismiss()
    }

    private func introductionPage(title: String, message: String, illustration: Int) -> some View {
        ScrollView {
            VStack(spacing: 24) {
                illustrationCard(illustration)
                    .accessibilityHidden(true)
                VStack(spacing: 12) {
                    Text("Preview")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                    Text(title)
                        .font(.largeTitle.bold())
                    Text(message)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

                if illustration == 2 {
                    Text("Optional preview. Turn it off anytime in More → Preview Features. Environment switching is hidden while it’s on.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    if !manager.allEnvironmentsPreview {
                        Button {
                            manager.allEnvironmentsPreview = true
                            finish()
                        } label: {
                            Text("Enable Preview")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                }
            }
            .padding(24)
        }
    }

    private func illustrationCard(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 16) {
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
        .font(.title3)
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Radius.hero, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.hero, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
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
