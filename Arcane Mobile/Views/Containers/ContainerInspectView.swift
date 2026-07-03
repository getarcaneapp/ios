import SwiftUI
import UIKit
import Arcane

struct ContainerInspectView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    let container: ContainerSummary
    let environmentID: EnvironmentID

    @State private var rawJSON: String = ""
    /// Pre-split lines of `rawJSON`, computed once at load so keystroke
    /// filtering doesn't re-split the (potentially large) document each time.
    @State private var jsonLines: [String] = []
    /// The string body actually renders; updated by the debounced filter task.
    @State private var displayedJSON: String = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchText = ""

    var body: some View {
        Group {
            if isLoading && rawJSON.isEmpty {
                ProgressView("Loading inspect…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage, rawJSON.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text(errorMessage)
                        .multilineTextAlignment(.center)
                    Button("Retry") {
                        Task { await load() }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Text(displayedJSON)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(14)
                        .background(
                            Color(uiColor: .secondarySystemGroupedBackground),
                            in: .rect(cornerRadius: 14)
                        )
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                }
            }
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Inspect")
        .searchable(text: $searchText, prompt: "Filter lines")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = rawJSON
                    showToast(.copied("Inspect JSON copied"))
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .disabled(rawJSON.isEmpty)
            }
        }
        .task { await load() }
        .refreshable { await load() }
        // Debounced, off-main filtering: typing in the search field used to
        // re-split and re-filter the entire JSON document per keystroke in body.
        .task(id: searchText) {
            let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                displayedJSON = rawJSON
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let lines = jsonLines
            let filtered = await Task.detached(priority: .userInitiated) {
                lines
                    .filter { $0.localizedCaseInsensitiveContains(trimmed) }
                    .joined(separator: "\n")
            }.value
            guard !Task.isCancelled else { return }
            displayedJSON = filtered
        }
    }

    private func load() async {
        guard let client = manager.client else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let details = try await client.containers.inspect(envID: environmentID, id: container.id)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(details)
            let json = String(decoding: data, as: UTF8.self)
            rawJSON = json
            jsonLines = json.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                displayedJSON = json
            }
            errorMessage = nil
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }
}
