import SwiftUI
import Arcane

struct ImageHistoryView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    let imageID: String
    let environmentID: EnvironmentID

    @State private var items: [ImageHistoryItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading && items.isEmpty {
                SkeletonListLoadingView(rowCount: 5)
            } else if let errorMessage, items.isEmpty {
                ContentUnavailableView {
                    Label("Couldn't Load History", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try Again") { Task { await load() } }
                }
            } else if items.isEmpty {
                ContentUnavailableView(
                    "No Layer History",
                    systemImage: "square.stack.3d.down.right",
                    description: Text("This image did not return any layer history.")
                )
            } else {
                List(items) { item in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            MonospacedValue(value: layerID(item.id), lineLimit: 1)
                            Spacer(minLength: 8)
                            Text(item.size.byteString)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        if !item.createdBy.isEmpty {
                            MonospacedValue(value: item.createdBy, lineLimit: 3)
                        }
                        HStack {
                            if item.created > 0 {
                                Text(Date(timeIntervalSince1970: TimeInterval(item.created)), format: .dateTime.year().month().day())
                            }
                            if !item.tags.isEmpty {
                                Text(item.tags.joined(separator: ", "))
                                    .lineLimit(1)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                }
                .listStyle(.insetGrouped)
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func layerID(_ id: String) -> String {
        guard id != "<missing>" else { return "Metadata-only layer" }
        return id
    }

    private func load() async {
        guard let client = manager.client, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            items = try await client.images.history(envID: environmentID, imageID: imageID)
            errorMessage = nil
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }
}
