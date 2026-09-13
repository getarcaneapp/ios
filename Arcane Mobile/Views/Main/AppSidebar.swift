import SwiftUI
import Arcane

/// Permission-filtered destinations shared by the iPad sidebar and iPhone sheet.
struct AppSidebar: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(FleetStore.self) private var fleet
    @SwiftUI.Environment(ActivityHistoryMutationStore.self) private var historyMutationStore
    @State private var activityStore = ActivityCenterStore()
    @State private var showUpgrade = false
    @State private var router = QuickActionRouter.shared

    let tabs: [AppTab]
    let selectedID: String
    let onSelect: (String) -> Void

    private var selection: Binding<String?> {
        Binding(
            get: { selectedID },
            set: { if let destination = $0 { onSelect(destination) } }
        )
    }

    var body: some View {
        List(selection: selection) {
            Section {
                environmentSwitcher
                if showsUpgradeBanner {
                    Button {
                        showUpgrade = true
                    } label: {
                        Label("Arcane update available", systemImage: "arrow.up.circle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }

            ForEach(AppTab.Section.allCases, id: \.self) { section in
                let destinations = SidebarNavigation.destinations(in: section, available: tabs)
                if !destinations.isEmpty {
                    Section(section.title) {
                        ForEach(destinations) { tab in
                            Label(tab.title, systemImage: tab.systemImage)
                                .tag(tab.id)
                        }
                    }
                }
            }

            Section {
                Label("Profile", systemImage: "person.crop.circle")
                    .tag(SidebarUtilityDestination.profile.rawValue)
                Label("App Settings", systemImage: "gearshape")
                    .tag(SidebarUtilityDestination.appSettings.rawValue)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Arcane")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    router.openActivityCenter()
                } label: {
                    Label("Activity Center", systemImage: "clock.arrow.circlepath")
                }
                .labelStyle(.iconOnly)
            }
        }
        .task(id: manager.client.map { ObjectIdentifier($0.transport) }) {
            await fleet.load(manager: manager)
            fleet.setVisible(true, consumer: "sidebar", supportsDashboardStream: manager.supportsActivities)
            guard manager.supportsActivities else { return }
            activityStore.configure(client: manager.client)
            await activityStore.load()
            activityStore.startStream()
        }
        .onDisappear {
            activityStore.stopStream()
            fleet.setVisible(false, consumer: "sidebar", supportsDashboardStream: manager.supportsActivities)
        }
        .onChange(of: historyMutationStore.latestClear) { _, event in
            guard let event else { return }
            activityStore.removeClearedHistory(environmentIDs: event.environmentIDs)
            Task { await activityStore.load(refresh: true) }
        }
        .sheet(isPresented: $showUpgrade) {
            NavigationStack { SystemUpgradeView(environmentID: manager.activeEnvironmentID) }
        }
    }
    private var environmentSwitcher: some View {
        Menu {
            ForEach(fleet.environments) { environment in
                Button {
                    manager.setActiveEnvironment(
                        id: EnvironmentID(rawValue: environment.id),
                        name: environment.name ?? environment.id
                    )
                } label: {
                    if environment.id == manager.activeEnvironmentID.rawValue {
                        Label(environment.name ?? environment.id, systemImage: "checkmark")
                    } else {
                        Text(environment.name ?? environment.id)
                    }
                }
            }
        } label: {
            LabeledContent {
                Text(manager.activeEnvironmentName)
            } label: {
                Label("Environment", systemImage: "server.rack")
            }
        }
        .disabled(fleet.environments.isEmpty)
        .accessibilityLabel("Active environment: \(manager.activeEnvironmentName)")
    }

    private var showsUpgradeBanner: Bool {
        guard manager.permissions.has(Permission.System.upgrade),
              let state = fleet.dashboardStream.state(for: manager.activeEnvironmentID.rawValue),
              state.hasLoaded else { return false }
        return state.snapshot?.versionInfo?.updateAvailable == true
    }
}
