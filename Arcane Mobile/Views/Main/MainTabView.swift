import SwiftUI
import UIKit
import TipKit
import Arcane

struct MainTabView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @State private var selectedTab: String = AppTab.dashboard.id
    @State private var swapTarget: AppTab? = nil
    @State private var store = NavTabsStore.shared
    @State private var router = QuickActionRouter.shared
    @State private var morphStore = TabBarMorphStore.shared
    @State private var fleetStore = FleetStore()
    @State private var bottomBarScrollStore = BottomBarScrollStore()
    @AppStorage("accentColorHex") private var accentColorHex = ""
    @AppStorage(TabIndicatorMotion.storageKey) private var tabIndicatorMotion: TabIndicatorMotion = .straight

    init() {
        // Restore the last selected tab (opt-out via App Settings). Seeding the
        // initial State here instead of onAppear avoids a visible tab flash.
        // ensureSelectedTabVisible() falls back to the first reachable destination
        // if the saved tab is no longer available; quick-action routing still wins.
        let defaults = UserDefaults.standard
        let remember = defaults.object(forKey: "arcane.rememberLastTab") as? Bool ?? true
        if remember,
           let saved = defaults.string(forKey: "arcane.lastSelectedTabID"),
           !saved.isEmpty {
            _selectedTab = State(initialValue: saved)
        }
    }

    private var availableTabs: [AppTab] {
        AppTab.allCases.filter(manager.canAccess)
    }

    private var availableTabSet: Set<AppTab> {
        Set(availableTabs)
    }

    /// The configured accent (matches `Arcane_MobileApp`), used to tint the
    /// morphing bar's selected-tab indicator.
    private var accentColor: Color {
        guard !accentColorHex.isEmpty, let color = Color(hex: accentColorHex) else {
            return .accentColor
        }
        return color
    }

    private var visibleTabs: [AppTab] {
        store.visibleTabs(availableTabs: availableTabSet)
    }

    private var allowedDestinationIDs: [String] {
        visibleTabs.map(\.id) + [AppTab.settings.id]
    }

    /// Tabs for the morphing bar: the visible set plus the locked Settings slot.
    private var morphTabs: [MorphingTabBar.TabEntry] {
        visibleTabs.map {
            MorphingTabBar.TabEntry(
                id: $0.id,
                title: $0.tabBarTitle,
                symbol: $0.systemImage,
                isReplaceable: true
            )
        } + [
            MorphingTabBar.TabEntry(
                id: AppTab.settings.id,
                title: AppTab.settings.tabBarTitle,
                symbol: AppTab.settings.systemImage,
                isReplaceable: false
            )
        ]
    }

    private var dockContentClearance: CGFloat {
        return morphStore.isMorphed
            ? FloatingBottomBarMetrics.detailContentClearance
            : FloatingBottomBarMetrics.rootContentClearance
    }

    /// Scroll-driven compacting was removed — the bar stays expanded.
    private var isBottomBarCompact: Bool { false }

    @ViewBuilder
    private var coreTabView: some View {
        // The native tab bar is hidden per-tab (`.toolbar(.hidden, for: .tabBar)`)
        // — `MainTabView` overlays `MorphingTabBar` in its place so the bar can
        // morph into detail-page controls. The `TabView` still drives selection.
        TabView(selection: $selectedTab) {
            ForEach(visibleTabs) { tab in
                Tab(tab.tabBarTitle, systemImage: tab.systemImage, value: tab.id) {
                    TabNavigationContainer(tabID: tab.id, morphStore: morphStore) {
                        appTabDestination(tab, manager: manager, selectedTab: $selectedTab)
                    }
                    .tracksBottomBarScroll(
                        isActive: selectedTab == tab.id,
                        store: bottomBarScrollStore
                    )
                    .environment(\.currentTabID, tab.id)
                    .toolbar(.hidden, for: .tabBar)
                    .id(tab.isEnvironmentScoped ? "\(tab.id)-\(manager.activeEnvironmentID.rawValue)" : tab.id)
                }
            }
            Tab("Settings", systemImage: "gearshape.fill", value: "settings") {
                SettingsView(excludedTabs: Set(visibleTabs))
                    .tracksBottomBarScroll(
                        isActive: selectedTab == AppTab.settings.id,
                        store: bottomBarScrollStore
                    )
                    .environment(\.currentTabID, "settings")
                    .toolbar(.hidden, for: .tabBar)
            }
        }
    }

    /// The floating bottom bar. On iOS 26 it's the morph host
    /// (`TabReplaceMorphBar`) plus a tap-to-cancel scrim, so a long-press grows
    /// the bar into the tab picker. On iOS 18 it's the plain bar (long-press opens
    /// `TabSwapSheet`). Both pin a fixed gap above the physical bottom — fill the
    /// height, bottom-align, then ignore the safe area so the bar sits within it.
    @ViewBuilder
    private var bottomBarOverlay: some View {
        if #available(iOS 26, *) {
            ZStack(alignment: .bottom) {
                // Dim + tap-to-cancel behind the expanded picker. Always mounted;
                // only catches touches (and dims) while a replace is in flight.
                Button {
                    swapTarget = nil
                } label: {
                    Color.black
                        .opacity(swapTarget != nil ? 0.15 : 0)
                        .ignoresSafeArea()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss Tab Picker")
                .accessibilityHidden(swapTarget == nil)
                .allowsHitTesting(swapTarget != nil)
                .motionAwareAnimation(Motion.state, value: swapTarget != nil)

                TabReplaceMorphBar(
                    tabs: morphTabs,
                    selectedID: $selectedTab,
                    store: morphStore,
                    accentColor: accentColor,
                    indicatorMotion: tabIndicatorMotion,
                    isCompact: isBottomBarCompact,
                    pinnedTabs: store.pinnedTabs,
                    swapTarget: $swapTarget,
                    availableTabs: availableTabSet,
                    onLongPressTab: handleLongPressTab,
                    onPick: handleMorphPick
                )
                .padding(.bottom, 18)
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
            .ignoresSafeArea()
        } else {
            MorphingTabBar(
                tabs: morphTabs,
                selectedID: $selectedTab,
                store: morphStore,
                onLongPressTab: handleLongPressTab,
                accentColor: accentColor,
                indicatorMotion: tabIndicatorMotion,
                isCompact: isBottomBarCompact
            )
            .padding(.bottom, 18)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var navigationContent: some View {
        dockModeView
    }

    private var dockModeView: some View {
        coreTabView
            .overlay(alignment: .bottom) {
                bottomBarOverlay
            }
    }

    var body: some View {
        navigationContent
            .environment(fleetStore)
            // Keep the installer outside the dock/sidebar branch so toggling
            // sidebar mode updates the existing controller to zero before the
            // dock hierarchy is removed. This prevents its bottom clearance from
            // leaking into sidebar pages as empty bottom space.
            .background {
                BottomBarInsetInstaller(barTop: dockContentClearance)
            }
            // Destructive-action confirmation for the morph bar's controls.
            // Mounted here (full-screen) rather than on the bar itself so the
            // dialog's overlay host isn't constrained to the bar capsule.
            .deleteConfirmation(
                item: Binding(
                    get: { morphStore.pendingDestructive },
                    set: { morphStore.pendingDestructive = $0 }
                )
            ) { item in
                DeleteConfirmationConfig(
                    title: morphStore.destructiveTitle(for: item),
                    message: item.confirmationMessage ?? morphStore.defaultConfirmMessage(for: item),
                    icon: item.systemImage,
                    actions: [DeleteConfirmationAction(title: item.title, action: item.action)]
                )
            }
            // iOS 18 keeps the modal `TabSwapSheet`; on iOS 26 the morph
            // (`TabReplaceMorphBar`) owns long-press replace, so the sheet is
            // suppressed there.
            .modifier(LegacySwapSheet(
                swapTarget: $swapTarget,
                manager: manager,
                onPick: { performSwap(current: $0, replacement: $1) }
            ))
            // Re-tap of the selected tab: pop to root. Tabs push through their
            // own inner NavigationStacks (item-driven destinations), so the
            // reliable route is popping the backing UINavigationControllers —
            // SwiftUI syncs its bindings the same way it does for the
            // interactive swipe-back.
            .onChange(of: morphStore.popToRootToken) { _, _ in
                guard let tabID = morphStore.popToRootTabID, tabID == selectedTab || tabID == "settings" else { return }
                bottomBarScrollStore.reset()
                popVisibleNavigationStacksToRoot()
                morphStore.clearTab(tabID)
            }
            .onChange(of: selectedTab) { _, newValue in
                bottomBarScrollStore.reset()
                morphStore.activeTabID = newValue
                UserDefaults.standard.set(newValue, forKey: "arcane.lastSelectedTabID")
            }
            .onChange(of: morphStore.isMorphed) { _, isMorphed in
                if isMorphed {
                    bottomBarScrollStore.reset()
                }
            }
            .onChange(of: router.pendingTabID) { _, newValue in
                guard let target = newValue else { return }
                routeToDestination(target)
                router.pendingTabID = nil
            }
            .onChange(of: allowedDestinationIDs) { _, _ in
                ensureSelectedTabVisible()
            }
            .onAppear {
                bottomBarScrollStore.reset()
                if let target = router.pendingTabID {
                    routeToDestination(target)
                    router.pendingTabID = nil
                }
                ensureSelectedTabVisible()
                morphStore.activeTabID = selectedTab
            }

    }

    /// Long-press on a tab (tabs state only) opens the swap sheet. Settings —
    /// the last slot — is locked and ignored.
    private func handleLongPressTab(_ idx: Int) {
        let tabs = visibleTabs
        guard idx >= 0, idx < tabs.count else { return }
        bottomBarScrollStore.reset()
        HapticsManager.medium()
        swapTarget = tabs[idx]
    }

    /// Apply a tab swap from the long-press replace flow. Shared by the iOS 26
    /// morph picker and the iOS 18 `TabSwapSheet`.
    private func performSwap(current: AppTab, replacement: AppTab) {
        HapticsManager.success()
        store.swap(pinned: current, with: replacement)
        if selectedTab == current.id { selectedTab = replacement.id }
        swapTarget = nil
    }

    /// The morph picker reports only the chosen replacement; `swapTarget` holds
    /// the tab being replaced.
    private func handleMorphPick(_ replacement: AppTab) {
        guard let current = swapTarget else { return }
        performSwap(current: current, replacement: replacement)
    }

    private func routeToDestination(_ destinationID: String) {
        selectedTab = destinationID
        ensureSelectedTabVisible()
    }

    private func ensureSelectedTabVisible() {
        let allowedIDs = allowedDestinationIDs
        if !allowedIDs.contains(selectedTab) {
            selectedTab = allowedIDs.first ?? AppTab.settings.id
        }
    }
}

// MARK: - Scroll-driven tab-bar compaction

private struct BottomBarScrollTrackingModifier: ViewModifier {
    let isActive: Bool
    let store: BottomBarScrollStore

    func body(content: Content) -> some View {
        content
            // This modifier intentionally wraps the page hierarchy rather than
            // each individual List/ScrollView. SwiftUI binds it to the first
            // scroll view below the page, which is the root vertical scroller.
            .onScrollGeometryChange(for: BottomBarScrollSample.self) { geometry in
                let offset = geometry.contentOffset.y + geometry.contentInsets.top
                let scrollableHeight = geometry.contentSize.height
                    + geometry.contentInsets.top
                    + geometry.contentInsets.bottom
                let maximumOffset = max(
                    0,
                    scrollableHeight - geometry.containerSize.height
                )

                return BottomBarScrollSample(
                    verticalOffset: offset.rounded(.towardZero),
                    maximumVerticalOffset: maximumOffset.rounded(.towardZero),
                    isVerticallyScrollable: maximumOffset > 1
                )
            } action: { _, sample in
                guard isActive else { return }
                store.observe(sample)
            }
    }
}

private extension View {
    func tracksBottomBarScroll(
        isActive: Bool,
        store: BottomBarScrollStore
    ) -> some View {
        modifier(BottomBarScrollTrackingModifier(isActive: isActive, store: store))
    }
}

// MARK: - Legacy (iOS 18) swap sheet

/// Presents `TabSwapSheet` for long-press replace on iOS 18 only. On iOS 26 the
/// `TabReplaceMorphBar` morph owns that flow, so the sheet must not also fire off
/// the same `swapTarget`.
private struct LegacySwapSheet: ViewModifier {
    @Binding var swapTarget: AppTab?
    let manager: ArcaneClientManager
    /// `(current, replacement)` — applied identically to the iOS 26 picker.
    let onPick: (AppTab, AppTab) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
        } else {
            content.sheet(item: $swapTarget) { current in
                TabSwapSheet(current: current) { replacement in
                    onPick(current, replacement)
                }
                .environment(manager)
            }
        }
    }
}

// The long-press "swap a tab" gesture used to hook the native `UITabBar` via a
// `TabBarLongPressInstaller`, and a `tabViewBottomAccessory` hint banner pointed
// at it. Both are gone now that `MorphingTabBar` owns the bar: the long-press
// lives on the bar's custom tab buttons (`onLongPressTab`, gated to the
// non-morphed state) and is wired up in `body` via `handleLongPressTab`.

// MARK: - Per-tab navigation container

/// Wraps a tab's `NavigationStack` with an explicit path so we can drop the morph
/// the *instant* navigation returns to the root list — the detail page's own
/// `onDisappear` fires only when the pop (and its zoom transition) finishes, which
/// left the controls bar lingering. (Content clearance for the floating bar is
/// handled globally by `BottomBarInsetInstaller`.)
private struct TabNavigationContainer<Content: View>: View {
    let tabID: String
    let morphStore: TabBarMorphStore
    @ViewBuilder var content: Content

    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            content
        }
        .onChange(of: path.isEmpty) { _, isEmpty in
            if isEmpty { morphStore.clearTab(tabID) }
        }
        // Re-tapping the selected tab in the floating bar pops this tab's
        // stack to root — the native tab bar behavior the custom bar replaces.
        .onChange(of: morphStore.popToRootToken) { _, _ in
            if morphStore.popToRootTabID == tabID, !path.isEmpty {
                path = NavigationPath()
            }
        }
    }
}

// MARK: - Pop to root (UIKit)

/// Pops every navigation stack under the selected tab back to its root.
/// Presented sheets are left alone (only child hierarchy is walked).
@MainActor
private func popVisibleNavigationStacksToRoot() {
    let windows = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap(\.windows)
    guard let window = windows.first(where: { $0.isKeyWindow }) ?? windows.first,
          let tabController = findTabBarController(window.rootViewController),
          let selected = tabController.selectedViewController else { return }
    for nav in navigationControllers(under: selected) where nav.viewControllers.count > 1 {
        nav.popToRootViewController(animated: true)
    }
}

@MainActor
private func findTabBarController(_ viewController: UIViewController?) -> UITabBarController? {
    guard let viewController else { return nil }
    if let tab = viewController as? UITabBarController { return tab }
    for child in viewController.children {
        if let found = findTabBarController(child) { return found }
    }
    return nil
}

@MainActor
private func navigationControllers(under viewController: UIViewController) -> [UINavigationController] {
    var result: [UINavigationController] = []
    if let nav = viewController as? UINavigationController { result.append(nav) }
    for child in viewController.children {
        result.append(contentsOf: navigationControllers(under: child))
    }
    return result
}

// MARK: - Global bottom inset for the floating bar

/// Restores the content inset the native tab bar used to provide. Because the
/// custom `MorphingTabBar` floats as an overlay (the native bar is hidden), no
/// page reserves space for it automatically. Setting `additionalSafeAreaInsets`
/// on the backing `UITabBarController` propagates to every tab, every pushed
/// page, and the nested Settings stack — one place, full coverage.
private struct BottomBarInsetInstaller: UIViewRepresentable {
    /// Distance from the physical screen bottom to the top of the floating bar.
    let barTop: CGFloat

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.generation &+= 1
        let barTop = self.barTop
        let generation = context.coordinator.generation
        DispatchQueue.main.async {
            apply(
                from: uiView,
                barTop: barTop,
                retries: 10,
                coordinator: context.coordinator,
                generation: generation
            )
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.generation &+= 1
        uiView.window?.rootViewController?
            .deepTabBarController()?
            .additionalSafeAreaInsets.bottom = 0
    }

    private func apply(
        from view: UIView,
        barTop: CGFloat,
        retries: Int,
        coordinator: Coordinator,
        generation: Int
    ) {
        guard coordinator.generation == generation else { return }
        guard let tabBarController = findTabBarController(from: view) else {
            if retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    apply(
                        from: view,
                        barTop: barTop,
                        retries: retries - 1,
                        coordinator: coordinator,
                        generation: generation
                    )
                }
            }
            return
        }
        // `additionalSafeAreaInsets` is added on top of the system inset (home
        // indicator), so subtract it to land content exactly at the bar's top.
        let systemBottom = view.window?.safeAreaInsets.bottom ?? 0
        let additional = max(0, barTop - systemBottom)
        if abs(tabBarController.additionalSafeAreaInsets.bottom - additional) > 0.5 {
            tabBarController.additionalSafeAreaInsets.bottom = additional
        }
    }

    final class Coordinator {
        var generation = 0
    }

    private func findTabBarController(from view: UIView) -> UITabBarController? {
        var responder: UIResponder? = view
        while let current = responder {
            if let tabBarController = current as? UITabBarController { return tabBarController }
            responder = current.next
        }
        return view.window?.rootViewController?.deepTabBarController()
    }
}

private extension UIViewController {
    func deepTabBarController() -> UITabBarController? {
        if let tabBarController = self as? UITabBarController { return tabBarController }
        for child in children {
            if let found = child.deepTabBarController() { return found }
        }
        return presentedViewController?.deepTabBarController()
    }
}
