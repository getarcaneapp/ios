import SwiftUI

/// iOS 26 host for the long-press "replace this tab" flow.
///
/// Renders the real `MorphingTabBar` and, on long-press, floats a Liquid Glass
/// **callout** above it: a compact tab picker with a soft "teardrop" pointer aimed
/// down at the tab being replaced. The callout grows from that tab (the scale
/// anchor sits on the pointer) and is dismissed by picking a replacement or
/// tapping the scrim (the scrim lives in `MainTabView`).
///
/// iOS 18 keeps the modal `TabSwapSheet` (wired in `MainTabView`); this view is
/// never built there.
@available(iOS 26, *)
struct TabReplaceMorphBar: View {
    let tabs: [MorphingTabBar.TabEntry]
    @Binding var selectedID: String
    let store: TabBarMorphStore
    var accentColor: Color = .accentColor
    let pinnedTabs: [AppTab]
    /// The tab the user long-pressed to replace; nil collapses the callout.
    @Binding var swapTarget: AppTab?
    let availableTabs: Set<AppTab>
    var onLongPressTab: (Int) -> Void
    var onPick: (AppTab) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Live footprint of the bar, measured so the callout can match the tab
    /// capsule's width and aim its pointer at the right tab.
    @State private var barSize: CGSize = .zero

    /// Horizontal padding `MorphingTabBar` puts around its tab capsule. The
    /// callout aligns to the capsule (not the full bar) so the pointer lands on
    /// the tab's true center.
    private let capsuleInset: CGFloat = 15

    /// Width of the tab capsule (and therefore the callout) within the bar.
    private var panelWidth: CGFloat {
        max(0, barSize.width - capsuleInset * 2)
    }

    var body: some View {
        MorphingTabBar(
            tabs: tabs,
            selectedID: $selectedID,
            store: store,
            onLongPressTab: onLongPressTab,
            accentColor: accentColor
        )
        .onGeometryChange(for: CGSize.self) { $0.size } action: { newValue in
            guard newValue.width > 0, newValue.height > 0 else { return }
            if newValue.isMeaningfullyDifferent(from: barSize) { barSize = newValue }
        }
        // While the picker is open the bar must not handle taps: tapping another
        // tab should fall through to the dismiss scrim (behind the bar), not switch
        // tabs while the popover lingers. The callout overlay below is added after
        // this, so it stays interactive.
        .allowsHitTesting(swapTarget == nil)
        .overlay(alignment: .bottom) {
            if let target = swapTarget, panelWidth > 0, barSize.height > 0 {
                TabReplaceCallout(
                    current: target,
                    panelWidth: panelWidth,
                    pointerX: pointerX(for: target),
                    pinnedTabs: pinnedTabs,
                    availableTabs: availableTabs,
                    onPick: onPick
                )
                // Float clear above the bar; the pointer reaches down to the tab
                // capsule's top edge (the bar insets its capsule 6pt vertically).
                .offset(y: -(barSize.height - 6))
                .transition(calloutTransition(for: target))
            }
        }
        // Drives the callout's grow/shrink transition. Reduce Motion → instant.
        .animation(Motion.reduced(Motion.morph, reduceMotion: reduceMotion), value: swapTarget?.id)
    }

    /// Center x of the replaced tab within the callout (which spans the capsule).
    private func pointerX(for target: AppTab) -> CGFloat {
        guard !tabs.isEmpty,
              let index = tabs.firstIndex(where: { $0.id == target.id }) else {
            return panelWidth / 2
        }
        return (CGFloat(index) + 0.5) / CGFloat(tabs.count) * panelWidth
    }

    /// Grow/shrink anchored on the pointer — i.e. out of, and back into, the tab
    /// being replaced.
    private func calloutTransition(for target: AppTab) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        let unitX = panelWidth > 0 ? pointerX(for: target) / panelWidth : 0.5
        let anchor = UnitPoint(x: min(max(unitX, 0), 1), y: 1)
        return .scale(scale: 0.18, anchor: anchor).combined(with: .opacity)
    }
}

// MARK: - Callout

/// The floating picker shown above the bar (iOS 26). A single-grid replacement
/// list on a Liquid Glass panel whose shape includes the downward pointer, so the
/// glass and its teardrop read as one continuous surface.
@available(iOS 26, *)
private struct TabReplaceCallout: View {
    let current: AppTab
    let panelWidth: CGFloat
    let pointerX: CGFloat
    let pinnedTabs: [AppTab]
    let availableTabs: Set<AppTab>
    let onPick: (AppTab) -> Void

    private let columns = 3
    private let cornerRadius: CGFloat = 24
    private let pointerWidth: CGFloat = 24
    private let pointerHeight: CGFloat = 11

    private var options: [AppTab] {
        AppTab.replacementOptions(
            current: current,
            pinned: Set(pinnedTabs),
            availableTabs: availableTabs
        )
    }

    private var shape: CalloutShape {
        CalloutShape(
            cornerRadius: cornerRadius,
            pointerWidth: pointerWidth,
            pointerHeight: pointerHeight,
            pointerX: pointerX
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Replace \(current.title)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            // No ScrollView: the option set is small and bounded, so the grid
            // hugs its content. (A ScrollView is greedy — it took a fixed 320pt
            // and left a tall empty panel.)
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: columns),
                spacing: 10
            ) {
                ForEach(options) { tab in
                    TabTile(tab: tab, onPick: onPick)
                }
            }
        }
        .padding(16)
        // Keep content clear of the pointer protruding from the bottom edge.
        .padding(.bottom, pointerHeight)
        .frame(width: panelWidth > 0 ? panelWidth : nil)
        .glassEffect(.regular, in: shape)
        // Hairline edge so the panel — and especially the teardrop pointer — stays
        // legible over dark content (plain glass has no defined edge there).
        .overlay { shape.stroke(.white.opacity(0.18), lineWidth: 0.5) }
    }
}

// MARK: - Callout shape

/// A rounded-rectangle panel with a soft, downward "teardrop" pointer along its
/// bottom edge, centered at `pointerX`. Used as the Liquid Glass shape for the
/// callout so the panel and its pointer are one continuous glass surface.
@available(iOS 26, *)
private nonisolated struct CalloutShape: Shape {
    var cornerRadius: CGFloat
    var pointerWidth: CGFloat
    var pointerHeight: CGFloat
    var pointerX: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = min(cornerRadius, rect.width / 2)
        let left = rect.minX
        let right = rect.maxX
        let top = rect.minY
        let bodyBottom = rect.maxY - pointerHeight   // body sits above the pointer
        let tipY = rect.maxY
        let halfBase = pointerWidth / 2
        let tipRound: CGFloat = 3   // rounded tip → teardrop, not a hard arrow

        // Center the pointer at `pointerX`, kept clear of the rounded corners.
        let minCx = left + r + halfBase
        let maxCx = right - r - halfBase
        let cx = min(max(left + pointerX, minCx), max(minCx, maxCx))

        // One continuous outline (body + pointer) so a stroke traces it with no
        // internal seam. Corners use quad curves (control at the true corner).
        var p = Path()
        p.move(to: CGPoint(x: left + r, y: top))
        p.addLine(to: CGPoint(x: right - r, y: top))
        p.addQuadCurve(to: CGPoint(x: right, y: top + r), control: CGPoint(x: right, y: top))
        p.addLine(to: CGPoint(x: right, y: bodyBottom - r))
        p.addQuadCurve(to: CGPoint(x: right - r, y: bodyBottom), control: CGPoint(x: right, y: bodyBottom))
        // bottom edge → into the pointer → back out
        p.addLine(to: CGPoint(x: cx + halfBase, y: bodyBottom))
        p.addLine(to: CGPoint(x: cx + tipRound, y: tipY - tipRound))
        p.addQuadCurve(to: CGPoint(x: cx - tipRound, y: tipY - tipRound), control: CGPoint(x: cx, y: tipY))
        p.addLine(to: CGPoint(x: cx - halfBase, y: bodyBottom))
        p.addLine(to: CGPoint(x: left + r, y: bodyBottom))
        p.addQuadCurve(to: CGPoint(x: left, y: bodyBottom - r), control: CGPoint(x: left, y: bodyBottom))
        p.addLine(to: CGPoint(x: left, y: top + r))
        p.addQuadCurve(to: CGPoint(x: left + r, y: top), control: CGPoint(x: left, y: top))
        p.closeSubpath()
        return p
    }
}

@available(iOS 26, *)
private extension CGSize {
    func isMeaningfullyDifferent(from other: CGSize) -> Bool {
        abs(width - other.width) > 0.5 || abs(height - other.height) > 0.5
    }
}
