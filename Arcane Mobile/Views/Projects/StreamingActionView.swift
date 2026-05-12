import SwiftUI
import Arcane

struct StreamingActionView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.dismiss) private var dismiss

    let title: String
    let path: String
    let method: String
    let bodyData: Data?
    let onComplete: () async -> Void

    @State private var lines: [Entry] = []
    @State private var isRunning = true
    @State private var didFail = false
    @State private var errorMessage: String?

    private struct Entry: Identifiable {
        let id = UUID()
        let text: String
        let isError: Bool
    }

    init(title: String,
         path: String,
         method: String = "POST",
         body: Data? = nil,
         onComplete: @escaping () async -> Void = {}) {
        self.title = title
        self.path = path
        self.method = method
        self.bodyData = body
        self.onComplete = onComplete
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if lines.isEmpty {
                            HStack {
                                ProgressView().scaleEffect(0.8)
                                Text("Starting…").foregroundStyle(.secondary)
                            }
                            .padding(.top, 8)
                        }
                        ForEach(lines) { entry in
                            Text(entry.text)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(entry.isError ? .red : .primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(entry.id)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
                .onChange(of: lines.count) { _, _ in
                    if let last = lines.last {
                        withAnimation(.none) { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }
                        .disabled(isRunning)
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    if isRunning {
                        ProgressView().scaleEffect(0.8)
                    } else if didFail {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    } else {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
            }
            .task { await runStream() }
        }
        .interactiveDismissDisabled(isRunning)
    }

    private func runStream() async {
        guard let client = manager.client else {
            append(text: "No client available", isError: true)
            isRunning = false; didFail = true
            return
        }
        guard let url = URL(string: manager.serverURL) else {
            append(text: "Invalid server URL", isError: true)
            isRunning = false; didFail = true
            return
        }

        do {
            let stream = try await NDJSONStream.stream(
                StreamingProgressLine.self,
                client: client,
                serverURL: url,
                path: path,
                method: method,
                body: bodyData
            )
            for try await line in stream {
                let display = line.displayText
                if !display.isEmpty {
                    append(text: display, isError: line.error != nil)
                }
            }
            isRunning = false
            await onComplete()
        } catch let error as NDJSONError {
            append(text: error.errorDescription ?? "Stream failed", isError: true)
            isRunning = false; didFail = true
        } catch {
            append(text: friendlyErrorMessage(error), isError: true)
            isRunning = false; didFail = true
        }
    }

    private func append(text: String, isError: Bool) {
        lines.append(Entry(text: text, isError: isError))
        if lines.count > 2000 { lines.removeFirst(200) }
    }
}

nonisolated struct StreamingProgressLine: Decodable, Sendable {
    let type: String?
    let phase: String?
    let status: String?
    let service: String?
    let message: String?
    let error: String?
    let progress: String?
    let id: String?
    let stream: String?

    var displayText: String {
        if let error { return "Error: \(error)" }
        if let stream {
            return stream.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var parts: [String] = []
        if let service { parts.append("[\(service)]") }
        if let phase, let type { parts.append("\(type) \(phase)") }
        else if let phase { parts.append(phase) }
        else if let type { parts.append(type) }
        if let status { parts.append(status) }
        if let progress { parts.append(progress) }
        if let message { parts.append(message) }
        if parts.isEmpty, let id { parts.append("layer \(String(id.prefix(12)))") }
        return parts.joined(separator: " ")
    }
}
