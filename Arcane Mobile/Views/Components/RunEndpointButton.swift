import SwiftUI
import Arcane

struct RunEndpointButton: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    let title: String
    let systemImage: String
    let path: (ArcaneClient) -> String
    var destructive = false

    @State private var isRunning = false
    @State private var message: String?

    var body: some View {
        Button(role: destructive ? .destructive : nil) {
            Task { await run() }
        } label: {
            Label(isRunning ? "Running..." : title, systemImage: systemImage)
        }
        .disabled(isRunning)
        if let message {
            Text(message).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func run() async {
        guard let client = manager.client else { return }
        isRunning = true
        defer { isRunning = false }
        do {
            _ = try await client.transport.rawRequest(path(client), method: "POST", body: EmptyJSONObject())
            message = "Completed"
        } catch {
            message = friendlyErrorMessage(error)
        }
    }
}

private nonisolated struct EmptyJSONObject: Encodable, Sendable {}
