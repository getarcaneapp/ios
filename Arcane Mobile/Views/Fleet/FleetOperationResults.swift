import SwiftUI

struct FleetOperationResults: View {
    let store: FleetOperationStore

    var body: some View {
        ForEach(store.results) { result in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(result.name).font(.headline)
                    Spacer()
                    if result.finished {
                        Image(systemName: result.failed ? "exclamationmark.triangle" : "checkmark.circle")
                            .foregroundStyle(result.failed ? .orange : .green)
                    } else if result.status != "Waiting" { ProgressView() }
                }
                Text(result.status).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}
