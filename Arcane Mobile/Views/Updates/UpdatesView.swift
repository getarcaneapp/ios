import SwiftUI
import Arcane

struct UpdatesView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    let environmentID: EnvironmentID

    @State private var showUpdaterRun = false
    @State private var runningActionID: String?
    @State private var checkMessage: String?

    var body: some View {
        List {
            Section {
                NavigationLink {
                    ImageUpdatesView(environmentID: environmentID, images: [])
                } label: {
                    Label("Image Updates", systemImage: "photo.stack")
                }
                DynamicNavigationRow(
                    title: "Updater History",
                    subtitle: "Recent update runs",
                    systemImage: "clock.arrow.circlepath"
                ) {
                    UpdaterHistoryView(environmentID: environmentID)
                }
            }

            if let checkMessage {
                Section {
                    Text(checkMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Updates")
        .navigationDestination(isPresented: $showUpdaterRun) {
            UpdaterRunView(environmentID: environmentID)
        }
        .actionToolbar(
            items: [
                ActionButtonItem(
                    id: "run-updater",
                    title: "Run Updater",
                    systemImage: "play.fill",
                    tint: .orange
                ) {
                    showUpdaterRun = true
                },
                ActionButtonItem(
                    id: "check-images",
                    title: "Check Images",
                    systemImage: "arrow.clockwise",
                    tint: .accentColor
                ) {
                    Task { await checkAllImageUpdates() }
                }
            ],
            runningItemID: runningActionID,
            isDisabled: runningActionID != nil
        )
    }

    private func checkAllImageUpdates() async {
        guard let client = manager.client else { return }
        runningActionID = "check-images"
        defer { runningActionID = nil }
        do {
            let path = client.rest.environmentPath(environmentID, "image-updates/check-all")
            _ = try await client.transport.rawRequest(path, method: "POST", body: EmptyJSONObject())
            checkMessage = "Completed"
        } catch {
            checkMessage = friendlyErrorMessage(error)
        }
    }
}

private nonisolated struct EmptyJSONObject: Encodable, Sendable {}
