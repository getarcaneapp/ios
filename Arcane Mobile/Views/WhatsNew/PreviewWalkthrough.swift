import SwiftUI

/// Paged introduction for a preview feature: a Preview badge, title, and
/// message per page over an illustration card, with an Enable Preview button
/// on the last page. Marks itself seen under `seenKey` when dismissed.
struct PreviewWalkthrough<Illustration: View>: View {
    struct Page {
        let title: String
        let message: String
    }

    let pages: [Page]
    let seenKey: String
    /// Shown on the last page above the enable button.
    let footnote: String
    let isEnabled: Bool
    let enable: () -> Void
    @ViewBuilder let illustration: (Int) -> Illustration

    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    private var lastPage: Int { pages.count - 1 }

    var body: some View {
        NavigationStack {
            TabView(selection: $page) {
                ForEach(pages.indices, id: \.self) { index in
                    pageView(index).tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            // Keep the pager's viewport constant throughout interactive swipes.
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 8) {
                    ForEach(pages.indices, id: \.self) { index in
                        Circle()
                            .fill(index == page ? Color.accentColor : Color.secondary.opacity(0.25))
                            .frame(width: 7, height: 7)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Page \(page + 1) of \(pages.count)")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: page = min(page + 1, lastPage)
                    case .decrement: page = max(page - 1, 0)
                    @unknown default: break
                    }
                }
                .frame(maxWidth: .infinity)
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
        .onDisappear { markSeen() }
    }

    private func markSeen() {
        UserDefaults.standard.set(true, forKey: seenKey)
    }

    private func finish() {
        markSeen()
        dismiss()
    }

    private func pageView(_ index: Int) -> some View {
        ScrollView {
            VStack(spacing: 24) {
                illustrationCard(index)
                    .accessibilityHidden(true)
                VStack(spacing: 12) {
                    Text("Preview")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                    Text(pages[index].title)
                        .font(.largeTitle.bold())
                    Text(pages[index].message)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

                if index == lastPage {
                    Text(footnote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    if !isEnabled {
                        Button {
                            enable()
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
            illustration(index)
        }
        .font(.title3)
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: Radius.hero, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Radius.hero, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        }
    }
}
