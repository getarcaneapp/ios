import SwiftUI
import Arcane

struct NetworkTopologyView: View {
    let environmentID: EnvironmentID
    var body: some View {
        DynamicResourceListView(
            title: "Network Topology",
            systemImage: "point.topleft.down.curvedto.point.bottomright.up",
            path: { _, client in client.rest.environmentPath(environmentID, "networks/topology") }
        )
    }
}
