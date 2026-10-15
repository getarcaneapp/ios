import SwiftUI
import WhatsNewKit

extension View {
    func arcaneWhatsNewSheet() -> some View {
        modifier(AutomaticWhatsNewPresentationModifier())
    }
}

private struct AutomaticWhatsNewPresentationModifier: ViewModifier {
    @SwiftUI.Environment(\.whatsNew) private var whatsNewEnvironment
    @SwiftUI.Environment(\.isLaunchSplashPresented) private var isLaunchSplashPresented
    @State private var presentedWhatsNew: WhatsNewKit.WhatsNew?
    @State private var didEvaluate = false
    @State private var introduction: PreviewIntroduction?
    @AppStorage(AllEnvironmentsIntroduction.seenKey) private var hasSeenAllEnvironments = false
    @AppStorage(RefreshedDashboardIntroduction.seenKey) private var hasSeenRefreshedDashboard = false

    /// Preview walkthroughs, shown once each after What's New, one at a time.
    private enum PreviewIntroduction: Identifiable {
        case allEnvironments
        case refreshedDashboard
        var id: Self { self }
    }

    private var nextIntroduction: PreviewIntroduction? {
        if !hasSeenAllEnvironments { return .allEnvironments }
        if !hasSeenRefreshedDashboard { return .refreshedDashboard }
        return nil
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: isLaunchSplashPresented, initial: true) { _, isPresented in
                guard !isPresented, !didEvaluate else { return }
                didEvaluate = true
                presentedWhatsNew = whatsNewEnvironment.whatsNew()
                if presentedWhatsNew == nil { introduction = nextIntroduction }
            }
            .sheet(
                item: $presentedWhatsNew,
                onDismiss: {
                    introduction = nextIntroduction
                }
            ) { whatsNew in
                WhatsNewPresentationView(
                    whatsNew: whatsNew,
                    versionStore: whatsNewEnvironment.whatsNewVersionStore
                )
            }
            .sheet(
                item: $introduction,
                onDismiss: {
                    // Each walkthrough marks itself seen on dismissal; chain the next.
                    introduction = nextIntroduction
                }
            ) { introduction in
                switch introduction {
                case .allEnvironments: AllEnvironmentsIntroductionView()
                case .refreshedDashboard: RefreshedDashboardIntroductionView()
                }
            }
    }
}

struct WhatsNewPresentationView: View {
    let whatsNew: WhatsNewKit.WhatsNew
    var versionStore: WhatsNewVersionStore?

    @SwiftUI.Environment(\.dismiss) private var dismiss
    @State private var showsArchive = false

    init(
        whatsNew: WhatsNewKit.WhatsNew,
        versionStore: WhatsNewVersionStore? = nil
    ) {
        self.whatsNew = whatsNew
        self.versionStore = versionStore
    }

    var body: some View {
        NavigationStack {
            WhatsNewReleaseContent(whatsNew: whatsNew)
                .toolbar {
                    if let secondaryAction = whatsNew.secondaryAction {
                        AppToolbarItem(placement: .topBarLeading) {
                            Button {
                                secondaryAction.hapticFeedback?()
                                showsArchive = true
                            } label: {
                                Label("Previous Releases", systemImage: "clock.arrow.circlepath")
                            }
                        }
                    }

                    AppToolbarItem(placement: .confirmationAction) {
                        Button {
                            whatsNew.primaryAction.hapticFeedback?()
                            dismiss()
                            whatsNew.primaryAction.onDismiss?()
                        } label: {
                            Text(AttributedString(whatsNew.primaryAction.title.attributedString))
                        }
                    }
                }
        }
        .sheet(isPresented: $showsArchive) {
            WhatsNewArchiveView()
        }
        .onDisappear {
            versionStore?.save(presentedVersion: whatsNew.version)
        }
    }
}

private struct WhatsNewReleaseContent: View {
    let whatsNew: WhatsNewKit.WhatsNew

    @SwiftUI.Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView {
            VStack(spacing: 36) {
                Text(AttributedString(whatsNew.title.text.attributedString))
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)

                LazyVStack(alignment: .leading, spacing: 32) {
                    ForEach(whatsNew.features, id: \.self) { feature in
                        featureRow(feature)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 28)
            .padding(.bottom, 36)
        }
        .softTopScrollEdgeEffectCompat()
    }

    @ViewBuilder
    private func featureRow(_ feature: WhatsNew.Feature) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 12) {
                feature.image.view()
                featureText(feature)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        } else {
            HStack(alignment: .top, spacing: 14) {
                feature.image.view()
                    .frame(width: 36)
                featureText(feature)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func featureText(_ feature: WhatsNew.Feature) -> some View {
        let lines = feature.subtitle.attributedString.string
            .split(separator: "\n", omittingEmptySubsequences: false)

        let section = ReleaseNotes.all
            .first { $0.version == whatsNew.version.description }?
            .presentationSections.first { $0.title == feature.title.attributedString.string }
        let bullets =
            section?.bullets
            ?? lines.map { line in
                ReleaseNote.Bullet(line.hasPrefix("• ") ? String(line.dropFirst(2)) : String(line))
            }

        return VStack(alignment: .leading, spacing: 8) {
            Text(AttributedString(feature.title.attributedString))
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(bullets.enumerated()), id: \.offset) { _, bullet in
                    if let badge = bullet.badge {
                        BadgedReleaseNote(text: bullet.text, badge: badge)
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("•")
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                            Text(verbatim: bullet.text)
                        }
                    }
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A badged release note drawn as a tinted block quote: the badge label sits
/// in the card's outline, cutting the line, and the note fills the card.
private struct BadgedReleaseNote: View {
    let text: String
    let badge: ReleaseNote.Badge

    private let shape = RoundedRectangle(cornerRadius: Radius.nested, style: .continuous)

    private var label: some View {
        Text(badge.label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(badge.color)
            .padding(.horizontal, 5)
            .fixedSize()
    }

    var body: some View {
        Text(verbatim: text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 10)
            .background(badge.color.opacity(0.12), in: shape)
            .overlay {
                // The label hides the outline behind it so the text interrupts the line.
                shape
                    .strokeBorder(badge.color.opacity(0.5), lineWidth: 1)
                    .mask {
                        Rectangle()
                            .overlay(alignment: .topLeading) { legend.background(.black).blendMode(.destinationOut) }
                            .compositingGroup()
                    }
            }
            .overlay(alignment: .topLeading) { legend }
            .padding(.top, 6)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(badge.label): \(text)")
    }

    /// Centered vertically on the card's top edge, inset from the corner.
    private var legend: some View {
        label
            .alignmentGuide(.top) { $0[VerticalAlignment.center] }
            .alignmentGuide(.leading) { $0[.leading] - 10 }
    }
}

struct WhatsNewArchiveView: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(ReleaseNotes.previous) { note in
                NavigationLink {
                    WhatsNewReleaseContent(whatsNew: note.whatsNew())
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    Text(verbatim: "Version \(note.version)")
                }
            }
            .navigationTitle("Previous Releases")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}
