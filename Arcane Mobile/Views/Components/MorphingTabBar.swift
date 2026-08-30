import SwiftUI
import UIKit
import AnimatedTabBar

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
    nonisolated struct TabEntry: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
        let symbol: String
        let isReplaceable: Bool
    }

    let tabs: [TabEntry]
    @Binding var selectedID: String
    let store: TabBarMorphStore
    /// Fires on long-press of a tab while **not** morphed (tabs state only).
    var onLongPressTab: (Int) -> Void
    /// Tints the selected-tab indicator (follows the app's configured accent).
    var accentColor: Color = .accentColor
    /// Controls the path used by the selected-tab indicator.
    var indicatorMotion: TabIndicatorMotion = .straight
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
                AnimatedTabStrip(
                    tabs: tabs,
                    selectedID: $selectedID,
                    accentColor: accentColor,
                    indicatorMotion: indicatorMotion,
                    longPressEnabled: !isMorphed,
                    onLongPress: onLongPressTab,
                    onReselect: { tabID in
                        store.requestPopToRoot(tabID: tabID)
                    }
                )
                .opacity(isMorphed ? 0 : 1)
                .allowsHitTesting(!isMorphed)
                .accessibilityHidden(isMorphed)
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

// MARK: - Animated navigation tabs

/// Pure selection logic shared by the animated renderer, the UIKit interaction
/// layer, and unit tests. The selected tab id remains the source of truth.
nonisolated enum TabStripSelection {
    enum Action: Equatable, Sendable {
        case select(String)
        case reselect(String)
        case ignore
    }

    static func index(selectedID: String, in tabs: [MorphingTabBar.TabEntry]) -> Int {
        tabs.firstIndex { $0.id == selectedID } ?? 0
    }

    static func action(
        for index: Int,
        selectedID: String,
        in tabs: [MorphingTabBar.TabEntry]
    ) -> Action {
        guard tabs.indices.contains(index) else { return .ignore }
        let tabID = tabs[index].id
        return tabID == selectedID ? .reselect(tabID) : .select(tabID)
    }

    static func canReplace(index: Int, in tabs: [MorphingTabBar.TabEntry]) -> Bool {
        tabs.indices.contains(index) && tabs[index].isReplaceable
    }
}

/// Geometry for Arcane's compact selection marker. AnimatedTabBar lays out
/// every button in equal-width slots; keeping the marker calculation separate
/// makes that contract explicit and testable for both layout directions.
nonisolated enum TabStripLayout {
    static func indicatorCenterX(
        index: Int,
        count: Int,
        width: CGFloat,
        isRightToLeft: Bool
    ) -> CGFloat? {
        guard count > 0, (0..<count).contains(index), width > 0 else { return nil }
        let visualIndex = isRightToLeft ? count - index - 1 : index
        let slotWidth = width / CGFloat(count)
        return (CGFloat(visualIndex) + 0.5) * slotWidth
    }
}

/// Uses Exyte's component for the visual selection animation while a transparent
/// native control layer owns interaction and accessibility. This avoids the
/// package's tap gesture firing after a successful long press.
private struct AnimatedTabStrip: View {
    let tabs: [MorphingTabBar.TabEntry]
    @Binding var selectedID: String
    let accentColor: Color
    let indicatorMotion: TabIndicatorMotion
    let longPressEnabled: Bool
    let onLongPress: (Int) -> Void
    let onReselect: (String) -> Void

    private var activeIndex: Int {
        TabStripSelection.index(selectedID: selectedID, in: tabs)
    }

    private var selectedIndex: Binding<Int> {
        Binding(
            get: { activeIndex },
            set: { handleSelection($0) }
        )
    }

    var body: some View {
        ZStack {
            AnimatedTabStripVisuals(
                tabs: tabs,
                selectedIndex: selectedIndex,
                activeIndex: activeIndex,
                accentColor: accentColor,
                indicatorMotion: indicatorMotion
            )

            TabInteractionOverlay(
                tabs: tabs,
                activeIndex: activeIndex,
                longPressEnabled: longPressEnabled,
                onTap: handleSelection,
                onLongPress: onLongPress
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func handleSelection(_ index: Int) {
        switch TabStripSelection.action(for: index, selectedID: selectedID, in: tabs) {
        case .select(let tabID):
            selectedID = tabID
        case .reselect(let tabID):
            onReselect(tabID)
        case .ignore:
            break
        }
    }
}

/// The pure-SwiftUI visual layer is separate from the UIKit interaction layer
/// so it can be rendered directly in regression-test attachments.
struct AnimatedTabStripVisuals: View {
    let tabs: [MorphingTabBar.TabEntry]
    @Binding var selectedIndex: Int
    let activeIndex: Int
    let accentColor: Color
    var indicatorMotion: TabIndicatorMotion = .straight

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection

    private var selectionAnimation: Animation {
        Motion.reducedRequired(Motion.state, reduceMotion: reduceMotion)
    }

    var body: some View {
        ZStack {
            // The existing capsule supplies the glass. A single restrained wash
            // across its full bounds gives the icons contrast without drawing
            // AnimatedTabBar's rectangular lower bar inside it.
            Color.primary.opacity(0.06)

            TabSelectionIndicator(
                activeIndex: activeIndex,
                tabCount: tabs.count,
                color: accentColor,
                motion: indicatorMotion,
                isRightToLeft: layoutDirection == .rightToLeft,
                reduceMotion: reduceMotion
            )

            AnimatedTabBar(
                selectedIndex: $selectedIndex,
                views: tabs.map { AnimatedTabIcon(symbol: $0.symbol) }
            )
            // AnimatedTabBar reserves an 18-point row for its ball above the
            // buttons. Its fixed ball/notch treatment does not fit Arcane's
            // compact glass capsule, so keep the package's button layout and
            // tint animation while replacing that chrome with the slider above.
            .barColor(.clear)
            .selectedColor(accentColor)
            .unselectedColor(Color.secondary)
            .ballColor(.clear)
            .verticalPadding(0)
            .ballAnimation(selectionAnimation)
            .indentAnimation(selectionAnimation)
            .buttonsAnimation(selectionAnimation)
            .ballTrajectory(indicatorMotion.packageTrajectory)
            .offset(y: -9)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension TabIndicatorMotion {
    var packageTrajectory: AnimatedTabBar.BallTrajectory {
        switch self {
        case .straight: .straight
        case .parabolic: .parabolic
        case .teleport: .teleport
        }
    }
}

private struct TabSelectionIndicator: View {
    let activeIndex: Int
    let tabCount: Int
    let color: Color
    let motion: TabIndicatorMotion
    let isRightToLeft: Bool
    let reduceMotion: Bool

    @State private var sourceIndex: Int?
    @State private var destinationIndex: Int?
    @State private var progress: CGFloat = 1

    private let width: CGFloat = 24
    private let height: CGFloat = 3
    private let bottomInset: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            if let sourceX = TabStripLayout.indicatorCenterX(
                index: sourceIndex ?? activeIndex,
                count: tabCount,
                width: proxy.size.width,
                isRightToLeft: isRightToLeft
            ), let destinationX = TabStripLayout.indicatorCenterX(
                index: destinationIndex ?? activeIndex,
                count: tabCount,
                width: proxy.size.width,
                isRightToLeft: isRightToLeft
            ) {
                Capsule()
                    .fill(color)
                    .frame(width: width, height: height)
                    .modifier(
                        TabIndicatorMotionModifier(
                            progress: progress,
                            source: CGPoint(
                                x: sourceX,
                                y: proxy.size.height - bottomInset - height / 2
                            ),
                            destination: CGPoint(
                                x: destinationX,
                                y: proxy.size.height - bottomInset - height / 2
                            ),
                            motion: motion,
                            indicatorSize: CGSize(width: width, height: height)
                        )
                    )
            }
        }
        .onAppear {
            sourceIndex = activeIndex
            destinationIndex = activeIndex
            progress = 1
        }
        .onChange(of: activeIndex) { oldValue, newValue in
            sourceIndex = oldValue
            destinationIndex = newValue
            progress = 0

            guard !reduceMotion else {
                progress = 1
                return
            }

            Task { @MainActor in
                await Task.yield()
                withAnimation(Motion.state) {
                    progress = 1
                }
            }
        }
        .onChange(of: motion) {
            sourceIndex = activeIndex
            destinationIndex = activeIndex
            progress = 1
        }
        .onChange(of: isRightToLeft) {
            sourceIndex = activeIndex
            destinationIndex = activeIndex
            progress = 1
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct TabIndicatorMotionModifier: AnimatableModifier {
    var progress: CGFloat
    let source: CGPoint
    let destination: CGPoint
    let motion: TabIndicatorMotion
    let indicatorSize: CGSize

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let value = min(max(progress, 0), 1)
        let presentation = presentation(at: value)

        content
            .scaleEffect(presentation.scale)
            .opacity(presentation.opacity)
            .offset(
                x: presentation.point.x - indicatorSize.width / 2,
                y: presentation.point.y - indicatorSize.height / 2
            )
    }

    private func presentation(at value: CGFloat) -> (point: CGPoint, scale: CGFloat, opacity: Double) {
        switch motion {
        case .straight:
            return (interpolatedPoint(at: value), 1, 1)
        case .parabolic:
            var point = interpolatedPoint(at: value)
            point.y -= 16 * 4 * value * (1 - value)
            return (point, 1, 1)
        case .teleport:
            let point = value < 0.5 ? source : destination
            let visibility = value < 0.2
                ? 1 - value / 0.2
                : value > 0.8 ? (value - 0.8) / 0.2 : 0
            return (point, max(visibility, 0.001), Double(visibility))
        }
    }

    private func interpolatedPoint(at value: CGFloat) -> CGPoint {
        CGPoint(
            x: source.x + (destination.x - source.x) * value,
            y: source.y + (destination.y - source.y) * value
        )
    }
}

private struct AnimatedTabIcon: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .symbolRenderingMode(.monochrome)
            .font(.system(size: 23, weight: .regular))
            .frame(width: 44, height: 24)
    }
}

/// Equal-width transparent buttons layered over AnimatedTabBar. Native buttons
/// retain keyboard and assistive-technology activation, while their long-press
/// recognizers cancel touch-up so replacing a tab never also selects it.
private struct TabInteractionOverlay: UIViewRepresentable {
    let tabs: [MorphingTabBar.TabEntry]
    let activeIndex: Int
    let longPressEnabled: Bool
    let onTap: (Int) -> Void
    let onLongPress: (Int) -> Void

    @Environment(\.layoutDirection) private var layoutDirection

    func makeUIView(context: Context) -> UIStackView {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .fill
        stack.distribution = .fillEqually
        stack.spacing = 0
        context.coordinator.rebuild(stack, tabs: tabs)
        update(stack, coordinator: context.coordinator)
        return stack
    }

    func updateUIView(_ uiView: UIStackView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.tabs != tabs {
            context.coordinator.rebuild(uiView, tabs: tabs)
        }
        update(uiView, coordinator: context.coordinator)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UIStackView,
        context: Context
    ) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    private func update(_ stack: UIStackView, coordinator: Coordinator) {
        stack.semanticContentAttribute = layoutDirection == .rightToLeft
            ? .forceRightToLeft
            : .forceLeftToRight
        coordinator.updateButtons(activeIndex: activeIndex)
    }

    final class Coordinator: NSObject {
        var parent: TabInteractionOverlay
        var tabs: [MorphingTabBar.TabEntry] = []

        init(parent: TabInteractionOverlay) {
            self.parent = parent
        }

        func rebuild(_ stack: UIStackView, tabs: [MorphingTabBar.TabEntry]) {
            tabsStackView = stack
            for view in stack.arrangedSubviews {
                stack.removeArrangedSubview(view)
                view.removeFromSuperview()
            }

            for (index, tab) in tabs.enumerated() {
                let button = UIButton(type: .custom)
                button.tag = index
                button.backgroundColor = .clear
                button.accessibilityIdentifier = "bottom-tab-\(tab.id)"
                button.addTarget(
                    self,
                    action: #selector(handleTap(_:)),
                    for: .primaryActionTriggered
                )

                if tab.isReplaceable {
                    let longPress = UILongPressGestureRecognizer(
                        target: self,
                        action: #selector(handleLongPress(_:))
                    )
                    longPress.minimumPressDuration = 0.4
                    longPress.cancelsTouchesInView = true
                    button.addGestureRecognizer(longPress)
                }

                stack.addArrangedSubview(button)
            }
            self.tabs = tabs
        }

        func updateButtons(activeIndex: Int) {
            guard let buttons = buttonViews else { return }
            for (index, button) in buttons.enumerated() where tabs.indices.contains(index) {
                let tab = tabs[index]
                var traits: UIAccessibilityTraits = .button
                if index == activeIndex { traits.insert(.selected) }
                button.accessibilityLabel = tab.title
                button.accessibilityTraits = traits
                button.accessibilityHint = tab.isReplaceable
                    ? "Double-tap to open. Use Replace Tab to customize."
                    : "Double-tap to open."

                for recognizer in button.gestureRecognizers ?? [] where recognizer is UILongPressGestureRecognizer {
                    recognizer.isEnabled = parent.longPressEnabled && tab.isReplaceable
                }

                if parent.longPressEnabled, tab.isReplaceable {
                    button.accessibilityCustomActions = [
                        UIAccessibilityCustomAction(name: "Replace Tab") { [weak self] _ in
                            guard let self else { return false }
                            self.parent.onLongPress(index)
                            return true
                        }
                    ]
                } else {
                    button.accessibilityCustomActions = nil
                }
            }
        }

        private var buttonViews: [UIButton]? {
            guard let stack = tabsStackView else { return nil }
            return stack.arrangedSubviews.compactMap { $0 as? UIButton }
        }

        private weak var tabsStackView: UIStackView?

        @objc private func handleTap(_ button: UIButton) {
            parent.onTap(button.tag)
        }

        @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began,
                  parent.longPressEnabled,
                  let button = recognizer.view as? UIButton,
                  TabStripSelection.canReplace(index: button.tag, in: parent.tabs) else { return }
            parent.onLongPress(button.tag)
        }
    }
}
