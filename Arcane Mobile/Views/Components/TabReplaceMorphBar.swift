import SwiftUI

/// iOS 26 host for the bottom bar's long-press "replace this tab" flow.
///
/// Wraps the real `MorphingTabBar` (as the morph **label**) and a compact tab
/// picker (as the morph **content**) in `ExpandableGlassEffect`, so a long-press
/// grows the bar *upward* into the picker instead of presenting a modal sheet.
/// `progress` is driven by `swapTarget`: non-nil → expanded. At rest the wrapper
/// is a passthrough (see `ExpandableGlassEffect`), so the bar behaves exactly as
/// it does today — including its own tabs↔detail-controls morph.
///
/// iOS 18 keeps `TabSwapSheet` (wired in `MainTabView`); this view is never built
/// there.
@available(iOS 26, *)
struct TabReplaceMorphBar: View {
    let tabs: [MorphingTabBar.TabEntry]
    @Binding var selectedID: String
    let store: TabBarMorphStore
    var accentColor: Color = .accentColor
    let pinnedTabs: [AppTab]
    /// The tab the user long-pressed to replace; nil collapses the morph.
    @Binding var swapTarget: AppTab?
    let isAdmin: Bool
    let supportsV2: Bool
    var onLongPressTab: (Int) -> Void
    var onPick: (AppTab) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 0 = collapsed bar, 1 = fully expanded picker. Animated; `ExpandableGlassEffect`
    /// interpolates the morph off it.
    @State private var progress: CGFloat = 0
    /// Discrete on/off for the morph's Liquid Glass slab. Decoupled from the
    /// interpolated `progress`: true the instant an expand starts, false only
    /// once a collapse has fully settled — so the glass is torn down cleanly
    /// rather than lingering behind the bar after dismiss.
    @State private var morphing = false
    /// The live tabs-state footprint of the bar, measured so the morph grows from
    /// exactly where the bar sits.
    @State private var labelSize: CGSize = .zero
    /// The tab being replaced. Held independently of `swapTarget` so the picker
    /// keeps rendering through the collapse animation (and is pre-measured at rest).
    @State private var replacing: AppTab?

    private var cornerRadius: CGFloat {
        (labelSize.height > 0 ? labelSize.height : 60) / 2
    }

    var body: some View {
        ExpandableGlassEffect(
            alignment: .bottom,
            progress: progress,
            morphing: morphing,
            labelSize: labelSize == .zero ? CGSize(width: 100, height: 60) : labelSize,
            cornerRadius: cornerRadius
        ) {
            TabReplacePopover(
                current: replacing ?? .dashboard,
                width: labelSize.width,
                pinnedTabs: pinnedTabs,
                isAdmin: isAdmin,
                supportsV2: supportsV2,
                onPick: onPick
            )
        } label: {
            MorphingTabBar(
                tabs: tabs,
                selectedID: $selectedID,
                store: store,
                onLongPressTab: onLongPressTab,
                accentColor: accentColor
            )
            .onGeometryChange(for: CGSize.self) { $0.size } action: { newValue in
                guard newValue.width > 0, newValue.height > 0 else { return }
                if newValue.isMeaningfullyDifferent(from: labelSize) {
                    labelSize = newValue
                }
            }
        }
        .onAppear {
            if replacing == nil { replacing = AppTab(rawValue: selectedID) ?? .dashboard }
        }
        .onChange(of: swapTarget) { _, newValue in
            if let newValue { replacing = newValue }
            let opening = newValue != nil
            // Glass on the instant we start expanding; off only once the collapse
            // has fully settled (and we're still closed — guards a fast re-open).
            // Bounce open, settle calmly closed.
            if opening { morphing = true }
            let animation = opening ? Motion.morph : Motion.morphCollapse
            withAnimation(Motion.reduced(animation, reduceMotion: reduceMotion)) {
                progress = opening ? 1 : 0
            } completion: {
                if !opening, swapTarget == nil { morphing = false }
            }
        }
    }
}

/// Compact, single-grid replacement picker shown inside the morph (iOS 26).
/// Section grouping and Reset live elsewhere — sections in the iOS 18
/// `TabSwapSheet`, Reset in Settings → Appearance.
@available(iOS 26, *)
private struct TabReplacePopover: View {
    let current: AppTab
    let width: CGFloat
    let pinnedTabs: [AppTab]
    let isAdmin: Bool
    let supportsV2: Bool
    let onPick: (AppTab) -> Void

    private let columns = 3

    private var options: [AppTab] {
        AppTab.replacementOptions(
            current: current,
            pinned: Set(pinnedTabs),
            isAdmin: isAdmin,
            supportsV2: supportsV2
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Replace \(current.title)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: columns),
                    spacing: 10
                ) {
                    ForEach(options) { tab in
                        TabTile(tab: tab, onPick: onPick)
                    }
                }
                .padding(.vertical, 2)
            }
            // Cap the panel so a long eligible list scrolls rather than growing
            // off-screen; short lists stay snug (no forced scroll/empty space).
            .frame(maxHeight: 320)
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(16)
        .frame(width: width > 0 ? width : nil)
    }
}

@available(iOS 26, *)
private extension CGSize {
    func isMeaningfullyDifferent(from other: CGSize) -> Bool {
        abs(width - other.width) > 0.5 || abs(height - other.height) > 0.5
    }
}
