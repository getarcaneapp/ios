import SwiftUI
import UIKit
import TipKit
import Arcane

struct MainTabView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedTab: String = AppTab.dashboard.id
    @State private var swapTarget: AppTab? = nil
    @State private var isSidebarPresented = false
    @State private var isSidebarDestinationRoot = true
    @State private var sidebarResetToken = 0
    @State private var store = NavTabsStore.shared
    @State private var router = QuickActionRouter.shared
    @State private var morphStore = TabBarMorphStore.shared
    @AppStorage("accentColorHex") private var accentColorHex = ""
    @AppStorage("arcane.sidebarNavigationEnabled") private var sidebarNavigationEnabled = false

    init() {
        // Restore the last selected tab (opt-out via App Settings). Seeding the
        // initial State here instead of onAppear avoids a visible tab flash.
        // ensureSelectedTabVisible() falls back to Dashboard if the saved tab is
        // no longer available, and quick-action routing still takes precedence.
        let defaults = UserDefaults.standard
        let remember = defaults.object(forKey: "arcane.rememberLastTab") as? Bool ?? true
        if remember,
           let saved = defaults.string(forKey: "arcane.lastSelectedTabID"),
           !saved.isEmpty {
            _selectedTab = State(initialValue: saved)
        }
    }

    private var isAdmin: Bool { manager.currentUser?.isAdmin == true }
    private var supportsV2: Bool { manager.serverCapabilities?.mode == .rbac }

    /// The configured accent (matches `Arcane_MobileApp`), used to tint the
    /// morphing bar's selected-tab indicator.
    private var accentColor: Color {
        guard !accentColorHex.isEmpty, let color = Color(hex: accentColorHex) else {
            return .accentColor
        }
        return color
    }

    private var visibleTabs: [AppTab] {
        store.visibleTabs(isAdmin: isAdmin, supportsV2: supportsV2)
    }

    /// Sidebar mode is not constrained by dock eligibility: every destination
    /// the current user and backend can access is available as a top-level row.
    private var sidebarTabs: [AppTab] {
        AppTab.allCases.filter { tab in
            (isAdmin || !tab.requiresAdmin)
                && (supportsV2 || !tab.requiresV2)
        }
    }

    private var allowedDestinationIDs: [String] {
        if sidebarNavigationEnabled {
            return sidebarTabs.map(\.id) + [
                SidebarUtilityDestination.profile.rawValue,
                SidebarUtilityDestination.settings.rawValue
            ]
        }

        return visibleTabs.map(\.id) + [SidebarUtilityDestination.settings.rawValue]
    }

    /// Tabs for the morphing bar: the visible set plus the locked Settings slot.
    private var morphTabs: [MorphingTabBar.TabEntry] {
        visibleTabs.map { MorphingTabBar.TabEntry(id: $0.id, symbol: $0.systemImage) }
            + [MorphingTabBar.TabEntry(id: "settings", symbol: "gearshape.fill")]
    }

    private var sidebarDestinationIdentity: String {
        let environmentSuffix: String
        if let tab = AppTab(rawValue: selectedTab), tab.isEnvironmentScoped {
            environmentSuffix = manager.activeEnvironmentID.rawValue
        } else {
            environmentSuffix = "global"
        }
        return "\(selectedTab)#\(sidebarResetToken)#\(environmentSuffix)"
    }

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
                    .environment(\.currentTabID, tab.id)
                    .toolbar(.hidden, for: .tabBar)
                    .id(tab.isEnvironmentScoped ? "\(tab.id)-\(manager.activeEnvironmentID.rawValue)" : tab.id)
                }
            }
            Tab("Settings", systemImage: "gearshape.fill", value: "settings") {
                SettingsView()
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
                Color.black
                    .opacity(swapTarget != nil ? 0.15 : 0)
                    .ignoresSafeArea()
                    .allowsHitTesting(swapTarget != nil)
                    .onTapGesture { swapTarget = nil }
                    .motionAwareAnimation(Motion.state, value: swapTarget != nil)

                TabReplaceMorphBar(
                    tabs: morphTabs,
                    selectedID: $selectedTab,
                    store: morphStore,
                    accentColor: accentColor,
                    pinnedTabs: store.pinnedTabs,
                    swapTarget: $swapTarget,
                    isAdmin: isAdmin,
                    supportsV2: supportsV2,
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
                accentColor: accentColor
            )
            .padding(.bottom, 18)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var navigationContent: some View {
        if sidebarNavigationEnabled {
            sidebarModeView
        } else {
            dockModeView
        }
    }

    private var dockModeView: some View {
        coreTabView
            .overlay(alignment: .bottom) {
                bottomBarOverlay
            }
    }

    @ViewBuilder
    private var sidebarModeView: some View {
        if horizontalSizeClass == .regular {
            HStack(spacing: 0) {
                appSidebar
                    .frame(width: 300)

                Divider()

                sidebarDestination
            }
            .background(Color(uiColor: .systemBackground))
        } else {
            CompactSidebarDrawer(
                isPresented: $isSidebarPresented,
                isNavigationRoot: isSidebarDestinationRoot,
                sidebar: { appSidebar },
                content: { sidebarDestination }
            )
        }
    }

    private var appSidebar: some View {
        AppSidebar(
            tabs: sidebarTabs,
            selectedID: selectedTab,
            accentColor: accentColor,
            onSelect: navigateToSidebarDestination
        )
    }

    private var sidebarDestination: some View {
        SidebarDestinationContainer(
            selectedID: $selectedTab,
            manager: manager,
            morphStore: morphStore,
            accentColor: accentColor,
            showsMenuButton: horizontalSizeClass != .regular,
            openSidebar: { isSidebarPresented = true },
            onNavigationRootChange: { isSidebarDestinationRoot = $0 }
        )
        .id(sidebarDestinationIdentity)
    }

    var body: some View {
        navigationContent
            // Keep the installer outside the dock/sidebar branch so toggling
            // sidebar mode updates the existing controller to zero before the
            // dock hierarchy is removed. This prevents its 88pt clearance from
            // leaking into sidebar pages as empty bottom space.
            .background {
                BottomBarInsetInstaller(barTop: sidebarNavigationEnabled ? 0 : 88)
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
                guard !sidebarNavigationEnabled else { return }
                guard let tabID = morphStore.popToRootTabID, tabID == selectedTab || tabID == "settings" else { return }
                popVisibleNavigationStacksToRoot()
                morphStore.clearTab(tabID)
            }
            .onChange(of: selectedTab) { oldValue, newValue in
                if sidebarNavigationEnabled {
                    morphStore.clearTab(oldValue)
                    isSidebarDestinationRoot = true
                    isSidebarPresented = false
                }
                morphStore.activeTabID = newValue
                UserDefaults.standard.set(newValue, forKey: "arcane.lastSelectedTabID")
            }
            .onChange(of: router.pendingTabID) { _, newValue in
                guard let target = newValue else { return }
                routeToDestination(target)
                router.pendingTabID = nil
            }
            .onChange(of: allowedDestinationIDs) { _, _ in
                ensureSelectedTabVisible()
            }
            .onChange(of: sidebarNavigationEnabled) { _, _ in
                swapTarget = nil
                isSidebarPresented = false
                isSidebarDestinationRoot = true
                sidebarResetToken &+= 1
                morphStore.clearTab(selectedTab)
                if sidebarNavigationEnabled {
                    clearDockSafeAreaInset()
                }
                ensureSelectedTabVisible()
                morphStore.activeTabID = selectedTab
            }
            .onAppear {
                if let target = router.pendingTabID {
                    routeToDestination(target)
                    router.pendingTabID = nil
                }
                ensureSelectedTabVisible()
                morphStore.activeTabID = selectedTab
                if sidebarNavigationEnabled {
                    clearDockSafeAreaInset()
                }
            }

    }

    /// Long-press on a tab (tabs state only) opens the swap sheet. Settings —
    /// the last slot — is locked and ignored.
    private func handleLongPressTab(_ idx: Int) {
        let tabs = visibleTabs
        guard idx >= 0, idx < tabs.count else { return }
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

    private func navigateToSidebarDestination(_ destinationID: String) {
        morphStore.clearTab(selectedTab)
        sidebarResetToken &+= 1
        isSidebarDestinationRoot = true
        isSidebarPresented = false
        selectedTab = destinationID
        ensureSelectedTabVisible()
    }

    private func routeToDestination(_ destinationID: String) {
        if sidebarNavigationEnabled {
            morphStore.clearTab(selectedTab)
            sidebarResetToken &+= 1
            isSidebarDestinationRoot = true
            isSidebarPresented = false
        }
        selectedTab = destinationID
        ensureSelectedTabVisible()
    }

    private func clearDockSafeAreaInset() {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        for window in windows {
            findTabBarController(window.rootViewController)?.additionalSafeAreaInsets.bottom = 0
        }
    }

    private func ensureSelectedTabVisible() {
        let allowed = Set(allowedDestinationIDs)
        if !allowed.contains(selectedTab) {
            selectedTab = AppTab.dashboard.id
        }
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
                .aiAssistantToolbar()
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

// MARK: - Sidebar destination container

/// Hosts one selected sidebar destination. Unlike dock mode, only the active
/// destination exists, so changing (or reselecting) a sidebar row naturally
/// returns to that page's root without retaining dozens of hidden stacks.
private struct SidebarDestinationContainer: View {
    @Binding var selectedID: String
    let manager: ArcaneClientManager
    let morphStore: TabBarMorphStore
    let accentColor: Color
    let showsMenuButton: Bool
    let openSidebar: () -> Void
    let onNavigationRootChange: (Bool) -> Void

    @State private var path = NavigationPath()

    private var selectedTab: AppTab? {
        AppTab(rawValue: selectedID)
    }

    private var showsBottomActions: Bool {
        morphStore.isMorphed || !morphStore.activeRootActions.isEmpty
    }

    var body: some View {
        GeometryReader { proxy in
            destination
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .environment(\.currentTabID, selectedID)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if showsBottomActions {
                        Color.clear
                            .frame(height: max(0, 88 - proxy.safeAreaInsets.bottom))
                            .accessibilityHidden(true)
                    }
                }
                .overlay(alignment: .bottom) {
                    if showsBottomActions {
                        MorphingTabBar(
                            tabs: [],
                            selectedID: $selectedID,
                            store: morphStore,
                            onLongPressTab: { _ in },
                            accentColor: accentColor,
                            showsNavigationTabs: false
                        )
                        .padding(.bottom, 18)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .ignoresSafeArea()
                    }
                }
        }
    }

    @ViewBuilder
    private var destination: some View {
        if selectedID == SidebarUtilityDestination.profile.rawValue {
            NavigationStack(path: $path) {
                ProfileView()
                    .sidebarNavigationToolbar(isVisible: showsMenuButton && path.isEmpty, action: openSidebar)
                    .preservesSidebarNavigationBarMargins(isEnabled: showsMenuButton)
            }
            .onChange(of: path.isEmpty, initial: true) { _, isRoot in
                onNavigationRootChange(isRoot)
                if isRoot { morphStore.clearTab(selectedID) }
            }
        } else if selectedID == SidebarUtilityDestination.settings.rawValue {
            NavigationStack(path: $path) {
                AppSettingsView()
                    .sidebarNavigationToolbar(isVisible: showsMenuButton && path.isEmpty, action: openSidebar)
                    .preservesSidebarNavigationBarMargins(isEnabled: showsMenuButton)
            }
            .onChange(of: path.isEmpty, initial: true) { _, isRoot in
                onNavigationRootChange(isRoot)
                if isRoot { morphStore.clearTab(selectedID) }
            }
        } else if selectedTab == .dashboard {
            // Dashboard owns its NavigationStack and mounts the combined
            // menu-first toolbar directly on its root content.
            DashboardView(
                selectedTab: $selectedID,
                showsSidebarButton: showsMenuButton,
                onOpenSidebar: openSidebar,
                onNavigationRootChange: onNavigationRootChange
            )
        } else if let selectedTab {
            NavigationStack(path: $path) {
                appTabDestination(selectedTab, manager: manager, selectedTab: $selectedID)
                    .sidebarNavigationToolbar(isVisible: showsMenuButton && path.isEmpty, action: openSidebar)
                    .preservesSidebarNavigationBarMargins(isEnabled: showsMenuButton)
            }
            .onChange(of: path.isEmpty, initial: true) { _, isRoot in
                onNavigationRootChange(isRoot)
                if isRoot { morphStore.clearTab(selectedID) }
            }
        } else {
            NavigationStack {
                ContentUnavailableView("Page Unavailable", systemImage: "sidebar.left")
                    .sidebarNavigationToolbar(isVisible: showsMenuButton, action: openSidebar)
                    .preservesSidebarNavigationBarMargins(isEnabled: showsMenuButton)
            }
            .onAppear { onNavigationRootChange(true) }
        }
    }
}

/// Keeps `UINavigationBar` using the effective margins it had before the
/// compact drawer translated its view partly beyond the window. UIKit otherwise
/// recomputes those margins from the visible sliver, moving large titles and
/// navigation-drawer search fields independently of the rest of the page.
private struct SidebarNavigationBarMarginInstaller: UIViewRepresentable {
    let isEnabled: Bool

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.update(from: uiView, isEnabled: isEnabled)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.restore()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        private weak var navigationBar: UINavigationBar?
        private var originalInsetsLayoutMarginsFromSafeArea: Bool?
        private var originalDirectionalLayoutMargins: NSDirectionalEdgeInsets?
        private var stableDirectionalLayoutMargins: NSDirectionalEdgeInsets?
        private var generation = 0

        func update(from view: UIView, isEnabled: Bool) {
            generation &+= 1
            apply(from: view, isEnabled: isEnabled, retries: 10, generation: generation)
        }

        func restore() {
            generation &+= 1
            guard let navigationBar else { return }
            if let originalInsetsLayoutMarginsFromSafeArea {
                navigationBar.insetsLayoutMarginsFromSafeArea = originalInsetsLayoutMarginsFromSafeArea
            }
            if let originalDirectionalLayoutMargins {
                navigationBar.directionalLayoutMargins = originalDirectionalLayoutMargins
            }
            self.navigationBar = nil
            self.originalInsetsLayoutMarginsFromSafeArea = nil
            self.originalDirectionalLayoutMargins = nil
            stableDirectionalLayoutMargins = nil
        }

        private func apply(from view: UIView, isEnabled: Bool, retries: Int, generation: Int) {
            guard self.generation == generation else { return }
            guard let navigationController = navigationController(from: view) else {
                guard retries > 0 else { return }
                DispatchQueue.main.async { [weak self, weak view] in
                    guard let self, let view else { return }
                    self.apply(
                        from: view,
                        isEnabled: isEnabled,
                        retries: retries - 1,
                        generation: generation
                    )
                }
                return
            }

            let bar = navigationController.navigationBar
            if navigationBar !== bar {
                restore()
                self.generation = generation
                bar.layoutIfNeeded()
                navigationBar = bar
                originalInsetsLayoutMarginsFromSafeArea = bar.insetsLayoutMarginsFromSafeArea
                originalDirectionalLayoutMargins = bar.directionalLayoutMargins
                stableDirectionalLayoutMargins = directionalInsets(
                    from: bar.layoutMargins,
                    layoutDirection: bar.effectiveUserInterfaceLayoutDirection
                )
            }

            guard isEnabled, let stableDirectionalLayoutMargins else {
                restore()
                return
            }
            bar.insetsLayoutMarginsFromSafeArea = false
            bar.directionalLayoutMargins = stableDirectionalLayoutMargins
        }

        private func navigationController(from view: UIView) -> UINavigationController? {
            var responder: UIResponder? = view
            while let current = responder {
                if let navigationController = current as? UINavigationController {
                    return navigationController
                }
                if let viewController = current as? UIViewController,
                   let navigationController = viewController.navigationController {
                    return navigationController
                }
                responder = current.next
            }
            return nil
        }

        private func directionalInsets(
            from insets: UIEdgeInsets,
            layoutDirection: UIUserInterfaceLayoutDirection
        ) -> NSDirectionalEdgeInsets {
            NSDirectionalEdgeInsets(
                top: insets.top,
                leading: layoutDirection == .rightToLeft ? insets.right : insets.left,
                bottom: insets.bottom,
                trailing: layoutDirection == .rightToLeft ? insets.left : insets.right
            )
        }
    }
}

private extension View {
    func preservesSidebarNavigationBarMargins(isEnabled: Bool) -> some View {
        background {
            SidebarNavigationBarMarginInstaller(isEnabled: isEnabled)
                .frame(width: 0, height: 0)
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
