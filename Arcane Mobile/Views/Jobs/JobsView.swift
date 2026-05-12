import SwiftUI
import Arcane

struct JobsView: View {
    let environmentID: EnvironmentID

    var body: some View {
        List {
            Section {
                NavigationLink {
                    JobsListView(environmentID: environmentID)
                } label: {
                    Label("Jobs", systemImage: "play.square.stack")
                }
                NavigationLink {
                    JobScheduleConfigView(environmentID: environmentID)
                } label: {
                    Label("Schedules", systemImage: "calendar.badge.clock")
                }
            }
        }
        .navigationTitle("Jobs")
    }
}
