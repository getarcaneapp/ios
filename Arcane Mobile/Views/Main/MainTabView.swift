import Arcane
import SwiftUI

struct MainTabView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @State private var selectedTab: String = AppTab.dashboard.id
    @State private var store = NavTabsStore.shared
    @State private var router = QuickActionRouter.shared
    @State private var fleetStore = FleetStore()
    @AppStorage("arcane.showTabLabels") private var showTabLabels = false

    init() {
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

    private var visibleTabs: [AppTab] {
        store.visibleTabs(availableTabs: availableTabSet)
    }

    private var allowedDestinationIDs: [String] {
        visibleTabs.map(\.id) + [AppTab.settings.id]
    }

    @ViewBuilder
    private var tabs: some View {
        TabView(selection: $selectedTab) {
            ForEach(visibleTabs) { tab in
                Tab(value: tab.id) {
                    tabRoot(for: tab)
                } label: {
                    if showTabLabels {
                        Label(tab.tabBarTitle, systemImage: tab.systemImage)
                    } else {
                        Label(tab.tabBarTitle, systemImage: tab.systemImage)
                            .labelStyle(.iconOnly)
                    }
                }
                .accessibilityLabel(tab.tabBarTitle)
            }

            Tab(value: AppTab.settings.id) {
                moreRoot
            } label: {
                if showTabLabels {
                    Label("More", systemImage: "ellipsis.circle.fill")
                } else {
                    Label("More", systemImage: "ellipsis.circle.fill")
                        .labelStyle(.iconOnly)
                }
            }
            .accessibilityLabel("More")
        }
    }

    var body: some View {
        tabs
        .environment(fleetStore)
        .onChange(of: selectedTab) { _, newValue in
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
        .onAppear {
            if let target = router.pendingTabID {
                routeToDestination(target)
                router.pendingTabID = nil
            }
            ensureSelectedTabVisible()
        }
    }

    private func routeToDestination(_ destinationID: String) {
        selectedTab = destinationID
        ensureSelectedTabVisible()
    }

    private func ensureSelectedTabVisible() {
        guard !allowedDestinationIDs.contains(selectedTab) else { return }
        selectedTab = allowedDestinationIDs.first ?? AppTab.settings.id
    }

    @ViewBuilder
    private func tabRoot(for tab: AppTab) -> some View {
        let usesEnvironment = tab == .dashboard || tab.isEnvironmentScoped
        TabNavigationContainer(
            showsEnvironmentContext: usesEnvironment,
            resetsForEnvironmentChanges: usesEnvironment
        ) {
            appTabDestination(tab, manager: manager, selectedTab: $selectedTab)
        }
        .id(usesEnvironment
            ? "\(tab.id)-\(manager.activeEnvironmentID.rawValue)"
            : tab.id)
    }

    private var moreRoot: some View {
        SettingsView(
            visibleTabs: visibleTabs,
            selectedTab: $selectedTab
        )
    }

}

private struct TabNavigationContainer<Content: View>: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager

    let showsEnvironmentContext: Bool
    let resetsForEnvironmentChanges: Bool
    @ViewBuilder var content: Content

    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            content
                .environmentContext(
                    isVisible: showsEnvironmentContext,
                    onSelect: {
                        path = NavigationPath()
                    }
                )
        }
        .onChange(of: manager.activeEnvironmentID) { oldValue, newValue in
            if resetsForEnvironmentChanges, oldValue != newValue {
                path = NavigationPath()
            }
        }
    }
}
