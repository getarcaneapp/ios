import Arcane
import SwiftUI

struct MainTabView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @State private(set) var selectedTab: String
    @State private var store = NavTabsStore.shared
    @State private var router = QuickActionRouter.shared
    @State private var fleetStore = FleetStore()
    @State private var moreDestination: AppTab?
    @AppStorage("arcane.showTabLabels") private var showTabLabels = false

    init(defaults: UserDefaults = .standard) {
        let remember = defaults.object(forKey: "arcane.rememberLastTab") as? Bool ?? true
        if remember,
            let saved = defaults.string(forKey: "arcane.lastSelectedTabID"),
            !saved.isEmpty
        {
            self.selectedTab = saved
        } else {
            self.selectedTab = AppTab.dashboard.id
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
            .onDisappear {
                fleetStore.configure(client: nil)
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
        guard
            let destination = Self.resolveDestination(
                destinationID, visibleTabs: Set(visibleTabs), availableTabs: availableTabSet
            )
        else { return }
        moreDestination = destination.moreDestination
        selectedTab = destination.selectedTab.id
    }

    /// External navigation uses the same authorized destinations as More;
    /// the user's four pinned tabs only determine where the view is hosted.
    nonisolated static func resolveDestination(
        _ destinationID: String,
        visibleTabs: Set<AppTab>,
        availableTabs: Set<AppTab>
    ) -> (selectedTab: AppTab, moreDestination: AppTab?)? {
        guard let destination = AppTab(rawValue: destinationID) else { return nil }
        if destination == .settings { return (.settings, nil) }
        guard availableTabs.contains(destination) else { return nil }
        if visibleTabs.contains(destination) { return (destination, nil) }
        return (.settings, destination)
    }

    private func ensureSelectedTabVisible() {
        guard !allowedDestinationIDs.contains(selectedTab) else { return }
        selectedTab = allowedDestinationIDs.first ?? AppTab.settings.id
    }

    @ViewBuilder
    private func tabRoot(for tab: AppTab) -> some View {
        let usesEnvironment = tab == .dashboard || tab.isEnvironmentScoped
        TabNavigationContainer(
            showsEnvironmentContext: tab.isEnvironmentScoped,
            resetsForEnvironmentChanges: usesEnvironment
        ) {
            appTabDestination(tab, manager: manager, selectedTab: $selectedTab)
        }
        .id(
            usesEnvironment
                ? "\(tab.id)-\(manager.activeEnvironmentID.rawValue)-\(manager.allEnvironmentsPreview)-\(manager.clientGeneration)"
                : tab.id)
    }

    private var moreRoot: some View {
        SettingsView(
            visibleTabs: visibleTabs,
            selectedTab: $selectedTab,
            pendingDestination: $moreDestination
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
