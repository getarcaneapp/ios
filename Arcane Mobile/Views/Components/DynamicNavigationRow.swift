import SwiftUI

struct DynamicNavigationRow<Destination: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: systemImage)
                    .symbolRenderingMode(.hierarchical)
            }
        }
    }
}
