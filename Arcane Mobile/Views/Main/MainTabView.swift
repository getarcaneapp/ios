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
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        Color.clear.frame(height: MorphingTabBar.reservedHeight)
                    }
                    .environment(\.currentTabID, "settings")
                    .toolbar(.hidden, for: .tabBar)
            }
        }
    }

    var body: some View {
        coreTabView
            .overlay(alignment: .bottom) {
                MorphingTabBar(
                    tabs: morphTabs,
                    selectedID: $selectedTab,
                    store: morphStore,
                    onLongPressTab: handleLongPressTab,
                    accentColor: accentColor
                )
                // Pin the bar a fixed gap above the *physical* bottom (just above
                // the home indicator), like the native bar: fill the height and
                // bottom-align, then ignore the safe area so it sits within it.
                .padding(.bottom, 10)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .ignoresSafeArea()
            }
            .sheet(item: $swapTarget) { current in
                TabSwapSheet(current: current) { replacement in
                    HapticsManager.success()
                    store.swap(pinned: current, with: replacement)
                    if selectedTab == current.id { selectedTab = replacement.id }
                    swapTarget = nil
                }
                .environment(manager)
            }
            .onChange(of: selectedTab) { _, newValue in
                morphStore.activeTabID = newValue
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

    private func ensureSelectedTabVisible() {
        let allowed = Set(visibleTabs.map(\.id) + ["settings"])
        if !allowed.contains(selectedTab) {
            selectedTab = AppTab.dashboard.id
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
/// left the controls bar lingering. Also reserves the floating bar's footprint so
/// content clears it (a stack-level inset doesn't propagate into the List).
private struct TabNavigationContainer<Content: View>: View {
    let tabID: String
    let morphStore: TabBarMorphStore
    @ViewBuilder var content: Content

    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            content
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Color.clear.frame(height: MorphingTabBar.reservedHeight)
                }
        }
        .onChange(of: path.isEmpty) { _, isEmpty in
            if isEmpty { morphStore.clearTab(tabID) }
        }
    }
}
