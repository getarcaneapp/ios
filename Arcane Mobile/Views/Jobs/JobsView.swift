import Arcane
import SwiftUI

struct JobsView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(EnvironmentsStore.self) private var environmentsStore
    let environmentID: EnvironmentID
    /// All Environments preview: list and act on resources from every enabled environment.
    var allEnvironments = false

    var body: some View {
        List {
            Section {
                NavigationLink {
                    JobsListView(environmentID: environmentID, allEnvironments: allEnvironments)
                } label: {
                    Label("Jobs", systemImage: "play.square.stack")
                }
                NavigationLink {
                    if allEnvironments {
                        scheduleEnvironments
                    } else {
                        JobScheduleConfigView(environmentID: environmentID)
                    }
                } label: {
                    Label("Schedules", systemImage: "calendar.badge.clock")
                }
            }
        }
        .navigationTitle("Jobs")
    }

    /// Schedules are per-environment settings, so All Environments picks the
    /// environment to configure first.
    private var scheduleEnvironments: some View {
        List {
            Section {
                ForEach(environmentsStore.enabledEnvironments, id: \.id) { environment in
                    NavigationLink {
                        JobScheduleConfigView(
                            environmentID: EnvironmentID(rawValue: environment.id),
                            environmentName: environment.displayName
                        )
                    } label: {
                        Label(environment.displayName, systemImage: "server.rack")
                    }
                }
            }
        }
        .overlay {
            if environmentsStore.hasLoaded && environmentsStore.enabledEnvironments.isEmpty {
                ContentUnavailableView("No Environments", systemImage: "server.rack")
            }
        }
        .navigationTitle("Schedules")
        .task { await environmentsStore.load(manager: manager) }
        .refreshable { await environmentsStore.load(manager: manager, refresh: true) }
    }
}
