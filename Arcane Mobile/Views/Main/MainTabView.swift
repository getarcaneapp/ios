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
    @AppStorage("accentColorHex") private var accentColorHex = ""

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

    /// Tabs for the morphing bar: the visible set plus the locked Settings slot.
    private var morphTabs: [MorphingTabBar.TabEntry] {
        visibleTabs.map { MorphingTabBar.TabEntry(id: $0.id, symbol: $0.systemImage) }
            + [MorphingTabBar.TabEntry(id: "settings", symbol: "gearshape.fill")]
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

    var body: some View {
        coreTabView
            // Reserve room for the floating bar on every page (tabs, pushed
            // details, and the nested Settings stack) by insetting the backing
            // tab controller — the job the native tab bar used to do for us.
            .background {
                BottomBarInsetInstaller(barTop: 88)
            }
            .overlay(alignment: .bottom) {
                bottomBarOverlay
            }
            // iOS 18 keeps the modal `TabSwapSheet`; on iOS 26 the morph
            // (`TabReplaceMorphBar`) owns long-press replace, so the sheet is
            // suppressed there.
            .modifier(LegacySwapSheet(
                swapTarget: $swapTarget,
                manager: manager,
                onPick: { performSwap(current: $0, replacement: $1) }
            ))
            .onChange(of: selectedTab) { _, newValue in
                morphStore.activeTabID = newValue
                UserDefaults.standard.set(newValue, forKey: "arcane.lastSelectedTabID")
            }
            .onChange(of: router.pendingTabID) { _, newValue in
                guard let target = newValue else { return }
                selectedTab = target
                ensureSelectedTabVisible()
                router.pendingTabID = nil
            }
            .onChange(of: visibleTabs.map(\.id)) { _, _ in
                ensureSelectedTabVisible()
            }
            .onAppear {
                if let target = router.pendingTabID {
                    selectedTab = target
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

    private func ensureSelectedTabVisible() {
        let allowed = Set(visibleTabs.map(\.id) + ["settings"])
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
    }
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

    func updateUIView(_ uiView: UIView, context: Context) {
        let barTop = self.barTop
        DispatchQueue.main.async {
            apply(from: uiView, barTop: barTop, retries: 10)
        }
    }

    private func apply(from view: UIView, barTop: CGFloat, retries: Int) {
        guard let tabBarController = findTabBarController(from: view) else {
            if retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    apply(from: view, barTop: barTop, retries: retries - 1)
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
