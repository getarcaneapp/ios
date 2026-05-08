import SwiftUI
import UIKit
import Arcane

struct ContainerInspectView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    let container: ContainerInfo
    let environmentID: EnvironmentID

    @State private var rawJSON: String = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var copyConfirm = false

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
                ScrollView([.horizontal, .vertical]) {
                    Text(filteredJSON)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            }
        }
        .navigationTitle("Inspect")
        .searchable(text: $searchText, prompt: "Filter lines")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = rawJSON
                    copyConfirm = true
                } label: {
                    Image(systemName: copyConfirm ? "checkmark" : "doc.on.doc")
                }
                .disabled(rawJSON.isEmpty)
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .onChange(of: copyConfirm) { _, newValue in
            guard newValue else { return }
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                copyConfirm = false
            }
        }
    }

    private var filteredJSON: String {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return rawJSON }
        return rawJSON
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.localizedCaseInsensitiveContains(trimmed) }
            .joined(separator: "\n")
    }

    private func load() async {
        guard let client = manager.client else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let raw: JSONValue = try await client.containers.inspect(envID: environmentID, id: container.id)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(raw)
            rawJSON = String(decoding: data, as: UTF8.self)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
