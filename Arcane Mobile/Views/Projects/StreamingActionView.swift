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
        // Derive the (envID, projectID, suffix) from the configured path. The path
        // looks like `<envPath>/projects/<id>/<suffix>`.
        guard let dispatch = parseProjectAction(path: path) else {
            fail(with: "Unsupported streaming action")
            return
        }

        do {
            let stream = try makeStream(client: client, action: dispatch)
            for try await event in stream {
                let isError = event.error != nil
                let display = displayText(for: event)
                if !display.isEmpty {
                    append(text: display, isError: isError)
                }
                if !isError {
                    updatePhase(from: event)
                }
            }
            withAnimation(.smooth(duration: 0.25)) {
                status = .success
                currentPhase = "Complete"
            }
            await onComplete()
        } catch {
            let message = friendlyErrorMessage(error)
            append(text: message, isError: true)
            fail(with: message)
        }
    }

    private enum ProjectAction {
        case deploy(envID: EnvironmentID, projectID: String)
        case down(envID: EnvironmentID, projectID: String)
        case redeploy(envID: EnvironmentID, projectID: String)
        case pull(envID: EnvironmentID, projectID: String)
        case build(envID: EnvironmentID, projectID: String)
    }

    private func parseProjectAction(path: String) -> ProjectAction? {
        // Find ".../projects/{id}/{suffix}" — be lenient about anything before it.
        let components = path.split(separator: "/").map(String.init)
        guard let projectsIdx = components.lastIndex(of: "projects"),
              projectsIdx + 2 < components.count else {
            return nil
        }
        let projectID = components[projectsIdx + 1]
        let suffix = components[projectsIdx + 2]

        // Extract envID from the path. Default to "0" — the SDK handles `nil`/empty.
        var envIDString = "0"
        if let envsIdx = components.lastIndex(of: "environments"),
           envsIdx + 1 < components.count {
            envIDString = components[envsIdx + 1]
        }
        let envID = EnvironmentID(rawValue: envIDString)

        switch suffix {
        case "up":       return .deploy(envID: envID, projectID: projectID)
        case "down":     return .down(envID: envID, projectID: projectID)
        case "redeploy": return .redeploy(envID: envID, projectID: projectID)
        case "pull":     return .pull(envID: envID, projectID: projectID)
        case "build":    return .build(envID: envID, projectID: projectID)
        default:         return nil
        }
    }

    private func makeStream(client: ArcaneClient, action: ProjectAction) throws -> NDJSONStream<PullProgressEvent> {
        switch action {
        case let .deploy(envID, projectID):
            return try client.projects.deployStream(envID: envID, projectID: projectID)
        case let .down(envID, projectID):
            return client.projects.downStream(envID: envID, projectID: projectID)
        case let .redeploy(envID, projectID):
            return client.projects.redeployStream(envID: envID, projectID: projectID)
        case let .pull(envID, projectID):
            return try client.projects.pullImagesStream(envID: envID, projectID: projectID)
        case let .build(envID, projectID):
            return try client.projects.buildStream(envID: envID, projectID: projectID)
        }
    }

    private func displayText(for event: PullProgressEvent) -> String {
        if let error = event.error { return "Error: \(error)" }
        if let stream = event.stream {
            let trimmed = stream.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        var parts: [String] = []
        if let status = event.status, !status.isEmpty { parts.append(status) }
        if let id = event.id, !id.isEmpty, parts.isEmpty {
            parts.append("layer \(String(id.prefix(12)))")
        }
        if let progress = event.progress, !progress.isEmpty { parts.append(progress) }
        return parts.joined(separator: " ")
    }

    private func append(text: String, isError: Bool) {
        lines.append(InstallStreamLine(text: text, isError: isError))
        if lines.count > 2000 { lines.removeFirst(200) }
    }

    private func updatePhase(from event: PullProgressEvent) {
        let raw = event.status?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let phase = raw, !phase.isEmpty else { return }
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
