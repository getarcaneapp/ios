import SwiftUI
import UIKit

/// A floating bottom bar that shows the app's tabs and **morphs** into a detail
/// page's action controls when one is pushed.
///
/// Adapted from FXTabBar's `FlexibleTabbar` (Balaji Venkatesh, 2026): the same
/// "tabs capsule reshapes into a control capsule" idea, generalised from a fixed
/// 3-slot layout to an adaptive *primary + secondary pills + overflow* row, and
/// back-deployed to iOS 18 through the app's `GlassCompat` shims (`GlassEffect`
/// on iOS 26, frosted material on iOS 18).
///
/// State comes from `TabBarMorphStore`: list pages show the tabs, a registered
/// detail page shows its `Payload`.
struct MorphingTabBar: View {
    struct TabEntry: Identifiable, Equatable {
        let id: String
        let symbol: String
    }

    let tabs: [TabEntry]
    @Binding var selectedID: String
    let store: TabBarMorphStore
    /// Fires on long-press of a tab while **not** morphed (tabs state only).
    var onLongPressTab: (Int) -> Void
    /// Tints the selected-tab indicator (follows the app's configured accent).
    var accentColor: Color = .accentColor
    /// Sidebar mode hides navigation tabs but reuses the exact same root/detail
    /// action rendering. Dock mode keeps the default `true` behavior.
    var showsNavigationTabs: Bool = true

    /// Sizing for the tabs capsule and the morphed controls. The tabs capsule
    /// fills the available width — like the native floating tab bar — so only its
    /// height is fixed here.
    private let barHeight: CGFloat = 60      // capsule height (tabs state)
    private let primarySize: CGFloat = 48    // morphed primary — same size as the
    private let pillSize: CGFloat = 48       // pills; distinguished only by its tint

    private var isMorphed: Bool { store.isMorphed }
    private var payload: TabBarMorphStore.Payload? { store.activePayload }

    private var activeIndex: Int {
        tabs.firstIndex { $0.id == selectedID } ?? 0
    }

    private var rootActions: [ActionButtonItem] { store.activeRootActions }

    var body: some View {
        HStack(spacing: 10) {
            if showsNavigationTabs || isMorphed {
                GlassContainerCompat(spacing: 10) {
                    let layout = isMorphed
                        ? AnyLayout(HStackLayout(spacing: 10))
                        : AnyLayout(ZStackLayout())

                    layout {
                        if showsNavigationTabs || payload?.primary != nil {
                            primaryCapsule
                        }

                        if isMorphed, let payload {
                            ForEach(payload.inline) { item in
                                secondaryPill(item)
                            }
                            if !payload.overflow.isEmpty {
                                overflowPill(payload.overflow)
                            }
                        }
                    }
                }
            }

            // Root-page accessory pills (e.g. Updates: Run Updater / History).
            // Rendered OUTSIDE the glass container as their own glass circles —
            // inside it, Liquid Glass merges them with the tab capsule into
            // one lumpy shape.
            if !isMorphed {
                ForEach(rootActions) { item in
                    rootPill(item)
                }
            }
        }
        // Smooth morph both ways. The un-morph is triggered immediately by the
        // navigation path returning to root, so this is just the visual reshape.
        .motionAwareAnimation(.smooth(duration: 0.38), value: isMorphed)
        .motionAwareAnimation(Motion.state, value: payload?.runningItemID)
        .motionAwareAnimation(.smooth(duration: 0.38), value: rootActions.map(\.id))
        .padding(.horizontal, 15)
        .padding(.vertical, 6)
        // NOTE: the destructive confirmation for `store.pendingDestructive` is
        // mounted by MainTabView (full-screen ancestor) — attaching it here
        // constrained the dialog's overlay host to the bar capsule's tiny
        // frame and rendered the card smooshed.
    }

    // MARK: - Primary (the morphing capsule)

    private var primaryCapsule: some View {
        let primary = payload?.primary
        let isRunningPrimary = primary != nil && payload?.runningItemID == primary?.id

        return ZStack {
            if showsNavigationTabs {
                CustomTabBar(
                    tabs: tabs,
                    activeIndex: Binding(
                        get: { activeIndex },
                        set: { idx in
                            guard idx >= 0, idx < tabs.count else { return }
                            selectedID = tabs[idx].id
                        }
                    ),
                    selectedTint: accentColor,
                    longPressEnabled: !isMorphed,
                    onLongPress: onLongPressTab,
                    onReselect: { idx in
                        guard idx >= 0, idx < tabs.count else { return }
                        store.requestPopToRoot(tabID: tabs[idx].id)
                    }
                )
                .opacity(isMorphed ? 0 : 1)
                .allowsHitTesting(!isMorphed)
            }

            if let primary {
                Button {
                    handleTap(primary)
                } label: {
                    ZStack {
                        if isRunningPrimary {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: primary.systemImage)
                                .font(.title2)
                                .fontWeight(.semibold)
                                .foregroundStyle(.white)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(primary.title)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(.capsule)
                .opacity(isMorphed ? 1 : 0)
                .blur(radius: isMorphed ? 0 : 6)
                .disabled(!isMorphed || disabled(primary))
                .allowsHitTesting(isMorphed && !disabled(primary))
            }
        }
        // Tabs state fills the width like the native floating bar; morphed state
        // collapses to a primary-size circle.
        .frame(maxWidth: isMorphed ? primarySize : .infinity)
        .frame(height: isMorphed ? primarySize : barHeight)
        .clipShape(.capsule)
        // Morphed primary = a tinted, interactive chip (a *solid* fill on iOS 18
        // so the white glyph keeps contrast). Tabs capsule = plain glass/material,
        // non-interactive so pressing a tab doesn't depress the whole bar.
        .modifier(PrimaryCapsuleGlass(isMorphed: isMorphed, tint: primary?.tint))
    }

    // MARK: - Secondary pills

    private func secondaryPill(_ item: ActionButtonItem) -> some View {
        let isRunning = payload?.runningItemID == item.id
        let isDisabled = disabled(item)

        return Button {
            handleTap(item)
        } label: {
            ZStack {
                if isRunning {
                    ProgressView()
                        .controlSize(.regular)
                        .tint(item.tint)
                } else {
                    Image(systemName: item.systemImage)
                        .font(.title3)
                        .foregroundStyle(item.tint)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .frame(width: pillSize, height: pillSize)
        .contentShape(.circle)
        .glassEffectCompat(interactive: true, in: .circle)
        .opacity(isDisabled && !isRunning ? 0.45 : 1)
        .disabled(!isMorphed || isDisabled)
        .transition(.blurReplace.combined(with: .opacity))
    }

    /// Accessory pill for a root page's action — same look as `secondaryPill`,
    /// but enabled while the bar is showing tabs (secondary pills only exist
    /// morphed).
    private func rootPill(_ item: ActionButtonItem) -> some View {
        Button {
            handleTap(item)
        } label: {
            Image(systemName: item.systemImage)
                .font(.title3)
                .foregroundStyle(item.tint)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .frame(width: pillSize, height: pillSize)
        .contentShape(.circle)
        .glassEffectCompat(interactive: true, in: .circle)
        .transition(.blurReplace.combined(with: .opacity))
    }

    // MARK: - Overflow menu

    private func overflowPill(_ items: [ActionButtonItem]) -> some View {
        Menu {
            ForEach(items) { item in
                Button(role: menuRole(item)) {
                    handleTap(item)
                } label: {
                    Label(item.title, systemImage: item.systemImage)
                }
                // The app's global accent tint overrides the destructive-role
                // icon color in menus (title goes red, icon stays accent);
                // re-tint so the icon matches the text.
                .tint(menuRole(item) == .destructive ? .red : nil)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.title3)
                .foregroundStyle(.primary)
                .frame(width: pillSize, height: pillSize)
                .contentShape(.circle)
                .glassEffectCompat(interactive: true, in: .circle)
        }
        .accessibilityLabel("More Actions")
        .transition(.blurReplace.combined(with: .opacity))
    }

    // MARK: - Behaviour

    /// Routes destructive items through the shared dialog; everything else runs
    /// immediately (matches `ActionToolbarModifier.handleTap`).
    private func handleTap(_ item: ActionButtonItem) {
        if item.role == .destructive {
            store.pendingDestructive = item
        } else {
            item.action()
        }
    }

    /// While one action runs, the others dim and disable.
    private func disabled(_ item: ActionButtonItem) -> Bool {
        guard let payload else { return false }
        if payload.isDisabled { return true }
        if let running = payload.runningItemID, running != item.id { return true }
        return false
    }

    /// Red styling in the menu for either a destructive role or a red tint (so a
    /// bespoke-dialog delete still reads as destructive even with `role: nil`).
    private func menuRole(_ item: ActionButtonItem) -> ButtonRole? {
        if item.role == .destructive || item.tint == .red { return .destructive }
        return nil
    }

}

extension TabBarMorphStore {
    /// Confirmation title/message for a destructive morph-bar action, shared
    /// by whichever full-screen view hosts the dialog.
    func destructiveTitle(for item: ActionButtonItem) -> String {
        if let name = activePayload?.resourceName {
            return "\(item.title) \(name)?"
        }
        return "\(item.title)?"
    }

    func defaultConfirmMessage(for item: ActionButtonItem) -> String {
        if let name = activePayload?.resourceName {
            return "Are you sure you want to \(item.title.lowercased()) \(name)?"
        }
        return "Are you sure you want to \(item.title.lowercased())?"
    }
}

// MARK: - Primary capsule background

/// Background for the morphing primary button. Morphed → a tinted chip via
/// `glassChipCompat`, which is liquid glass on iOS 26 and a **solid** tint fill
/// on iOS 18 (so the white glyph keeps contrast — `glassEffectCompat`'s 0.15
/// wash is too faint there). Tabs → plain glass/material, non-interactive.
private struct PrimaryCapsuleGlass: ViewModifier {
    let isMorphed: Bool
    let tint: Color?

    func body(content: Content) -> some View {
        if isMorphed, let tint {
            content.glassChipCompat(tint: tint, interactive: true, in: .capsule)
        } else {
            content.glassEffectCompat(in: .capsule)
        }
    }
}

// MARK: - Tabs capsule (UISegmentedControl)

/// The tabs state of the bar. A `UISegmentedControl` in a glass capsule (FX's
/// approach, for the iOS 26 liquid-glass segmented look + its native sliding
/// selection), extended to take string tab ids, rebuild its segments when the
/// visible tab set changes, and expose a long-press → swap callback gated to the
/// non-morphed state.
private struct CustomTabBar: UIViewRepresentable {
    var tabs: [MorphingTabBar.TabEntry]
    @Binding var activeIndex: Int
    var selectedTint: Color
    var longPressEnabled: Bool
    var onLongPress: (Int) -> Void
    /// Fires when the already-selected tab is tapped again (`valueChanged`
    /// never fires for that) — used for the native pop-to-root behavior.
    var onReselect: (Int) -> Void = { _ in }

    func makeUIView(context: Context) -> UISegmentedControl {
        let control = UISegmentedControl()
        context.coordinator.rebuild(control, tabs: tabs)
        if activeIndex < control.numberOfSegments {
            control.selectedSegmentIndex = activeIndex
        }
        // Selected-tab indicator follows the accent (translucent so the glyph on
        // top stays legible against any accent or appearance).
        control.selectedSegmentTintColor = UIColor(selectedTint.opacity(0.4))
        control.backgroundColor = .clear

        control.addTarget(
            context.coordinator,
            action: #selector(Coordinator.didChange(_:)),
            for: .valueChanged
        )

        let lp = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        lp.minimumPressDuration = 0.4
        // Once the long-press fires, cancel the touch in the segmented control so
        // releasing doesn't also commit a tap (which would switch tabs).
        lp.cancelsTouchesInView = true
        lp.delegate = context.coordinator
        control.addGestureRecognizer(lp)
        context.coordinator.longPress = lp

        // Re-tap of the selected segment: the segmented control emits no
        // valueChanged for it, so a passive tap recognizer detects it.
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        control.addGestureRecognizer(tap)

        return control
    }

    func updateUIView(_ uiView: UISegmentedControl, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.symbols != tabs.map(\.symbol) {
            context.coordinator.rebuild(uiView, tabs: tabs)
        }
        if uiView.selectedSegmentIndex != activeIndex, activeIndex < uiView.numberOfSegments {
            uiView.selectedSegmentIndex = activeIndex
        }
        uiView.selectedSegmentTintColor = UIColor(selectedTint.opacity(0.4))
        context.coordinator.longPress?.isEnabled = longPressEnabled
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UISegmentedControl, context: Context) -> CGSize? {
        .init(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: CustomTabBar
        var symbols: [String] = []
        weak var longPress: UILongPressGestureRecognizer?

        init(parent: CustomTabBar) { self.parent = parent }

        func rebuild(_ control: UISegmentedControl, tabs: [MorphingTabBar.TabEntry]) {
            control.removeAllSegments()
            let config = UIImage.SymbolConfiguration(pointSize: 23, weight: .regular)
            for (index, tab) in tabs.enumerated() {
                let image = UIImage(
                    systemName: tab.symbol,
                    withConfiguration: config
                )
                control.insertSegment(with: image, at: index, animated: false)
            }
            symbols = tabs.map(\.symbol)
            if #available(iOS 26, *) {
                // iOS 26: hide the control's own divider/background image views so
                // the liquid glass shows through. These are NOT the segment icons
                // on iOS 26 — but they ARE on iOS 18, so this would blank the
                // icons there; iOS 18 clears its chrome via appearance APIs instead.
                DispatchQueue.main.async {
                    for subview in control.subviews.dropLast() where subview is UIImageView {
                        subview.alpha = 0
                    }
                }
            } else {
                // iOS 18: only drop the dividers. (Clearing the *background* image
                // here disables the native selected-segment indicator — so leave
                // the background, which is what `selectedSegmentTintColor` draws
                // the selection highlight onto.)
                control.setDividerImage(
                    UIImage(),
                    forLeftSegmentState: .normal,
                    rightSegmentState: .normal,
                    barMetrics: .default
                )
            }
        }

        @objc func didChange(_ control: UISegmentedControl) {
            let idx = control.selectedSegmentIndex
            guard idx >= 0, idx < parent.tabs.count else { return }
            parent.activeIndex = idx
        }

        @objc func handleTap(_ gr: UITapGestureRecognizer) {
            guard gr.state == .ended,
                  let control = gr.view as? UISegmentedControl,
                  control.bounds.width > 0,
                  control.numberOfSegments > 0 else { return }
            let slotWidth = control.bounds.width / CGFloat(control.numberOfSegments)
            let x = gr.location(in: control).x
            let idx = min(max(Int(x / slotWidth), 0), control.numberOfSegments - 1)
            // Only a tap on the segment that was ALREADY selected counts as a
            // re-select; ordinary tab switches go through valueChanged.
            guard idx == control.selectedSegmentIndex, idx == parent.activeIndex else { return }
            parent.onReselect(idx)
        }

        @objc func handleLongPress(_ gr: UILongPressGestureRecognizer) {
            guard gr.state == .began,
                  let control = gr.view as? UISegmentedControl,
                  control.bounds.width > 0,
                  control.numberOfSegments > 0 else { return }
            let slotWidth = control.bounds.width / CGFloat(control.numberOfSegments)
            let x = gr.location(in: control).x
            let idx = min(max(Int(x / slotWidth), 0), control.numberOfSegments - 1)
            // Open the replace picker for the pressed tab WITHOUT changing the
            // selection: a long-press must not navigate to that tab first (the
            // picker's pointer already anchors it, and we don't want to wait on a
            // tab switch). `cancelsTouchesInView` stops the segmented control from
            // committing the tap on release, which would navigate too.
            parent.onLongPress(idx)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
