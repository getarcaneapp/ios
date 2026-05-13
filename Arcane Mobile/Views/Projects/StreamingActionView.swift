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

    @State private var lines: [InstallStreamLine] = []
    @State private var status: InstallStreamStatus = .running
    @State private var seenPhases: [String] = []
    @State private var currentPhase: String? = nil

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
        InstallStreamSheet(
            title: title,
            status: status,
            currentPhase: currentPhase,
            seenPhases: seenPhases,
            lines: lines,
            onDismiss: { dismiss() }
        )
        .interactiveDismissDisabled(!status.isTerminal)
        .task { await runStream() }
    }

    private func runStream() async {
        guard let client = manager.client else {
            fail(with: "No client available")
            return
        }
        guard let url = URL(string: manager.serverURL) else {
            fail(with: "Invalid server URL")
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
                let isError = line.error != nil
                let display = line.displayText
                if !display.isEmpty {
                    append(text: display, isError: isError)
                }
                if !isError {
                    updatePhase(from: line)
                }
            }
            withAnimation(.smooth(duration: 0.25)) {
                status = .success
                currentPhase = "Complete"
            }
            await onComplete()
        } catch let error as NDJSONError {
            let message = error.errorDescription ?? "Stream failed"
            append(text: message, isError: true)
            fail(with: message)
        } catch {
            let message = friendlyErrorMessage(error)
            append(text: message, isError: true)
            fail(with: message)
        }
    }

    private func append(text: String, isError: Bool) {
        lines.append(InstallStreamLine(text: text, isError: isError))
        if lines.count > 2000 { lines.removeFirst(200) }
    }

    private func updatePhase(from line: StreamingProgressLine) {
        let raw = (line.phase?.trimmed.nilIfEmpty) ?? (line.status?.trimmed.nilIfEmpty)
        guard let phase = raw else { return }
        if phase == currentPhase { return }
        withAnimation(.smooth(duration: 0.25)) {
            currentPhase = phase
            if !seenPhases.contains(phase) {
                seenPhases.append(phase)
            }
        }
    }

    private func fail(with message: String) {
        withAnimation(.smooth(duration: 0.25)) {
            status = .failure(message)
            currentPhase = "Failed"
        }
        HapticsManager.warning()
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilIfEmpty: String? { isEmpty ? nil : self }
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
