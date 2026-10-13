import Arcane
import SwiftUI

/// `docker top` for a running container. Columns vary by host, so rows are
/// rendered from `titles` with PID / user / command pulled out when present.
struct ContainerProcessesView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    let containerID: String
    let environmentID: EnvironmentID

    @State private var list: ContainerProcessList?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var notRunning = false

    private var rows: [ProcessRow] {
        guard let list else { return [] }
        return list.processes.enumerated().map { index, values in
            ProcessRow(id: index, titles: list.titles, values: values)
        }
    }

    var body: some View {
        Group {
            if isLoading && list == nil {
                ArcaneLoadingView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if notRunning {
                ContentUnavailableView(
                    "Container Not Running",
                    systemImage: "stop.circle",
                    description: Text("Start the container to see its processes.")
                )
            } else if let errorMessage, list == nil {
                ContentUnavailableView {
                    Label("Couldn't Load Processes", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try Again") { Task { await load() } }
                }
            } else if rows.isEmpty {
                ContentUnavailableView(
                    "No Processes",
                    systemImage: "list.number",
                    description: Text("The container didn't report any processes.")
                )
            } else {
                List {
                    Section {
                        ForEach(rows) { row in
                            processRow(row)
                        }
                    } header: {
                        Text(verbatim: "\(rows.count) process\(rows.count == 1 ? "" : "es")")
                    }
                }
                .listStyle(.insetGrouped)
                .softTopScrollEdgeEffectCompat()
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func processRow(_ row: ProcessRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let pid = row.pid {
                    Text(verbatim: pid)
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.15), in: .rect(cornerRadius: Radius.small))
                        .foregroundStyle(.orange)
                }
                if let user = row.user {
                    Text(verbatim: user)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let command = row.command {
                MonospacedValue(value: command, lineLimit: 3)
            }
            if !row.extras.isEmpty {
                Text(verbatim: row.extras.map { "\($0.title) \($0.value)" }.joined(separator: " · "))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private func load() async {
        guard let client = manager.client, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let path = client.rest.environmentPath(
                environmentID, "containers/\(ArcaneAPIHelpers.escapedPathComponent(containerID))/processes")
            list = try await client.rest.get(path)
            notRunning = false
            errorMessage = nil
        } catch ArcaneError.conflict {
            notRunning = true
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }
}

private struct ProcessRow: Identifiable {
    struct Column {
        let title: String
        let value: String
    }

    let id: Int
    let pid: String?
    let user: String?
    let command: String?
    let extras: [Column]

    private static let pidTitles: Set<String> = ["PID"]
    private static let userTitles: Set<String> = ["USER", "UID"]
    private static let commandTitles: Set<String> = ["CMD", "COMMAND", "ARGS"]

    init(id: Int, titles: [String], values: [String]) {
        self.id = id
        var pid: String?
        var user: String?
        var command: String?
        var extras: [Column] = []
        for (index, value) in values.enumerated() {
            let title = index < titles.count ? titles[index].uppercased() : ""
            if pid == nil, Self.pidTitles.contains(title) {
                pid = value
            } else if user == nil, Self.userTitles.contains(title) {
                user = value
            } else if command == nil, Self.commandTitles.contains(title) {
                command = value
            } else if !value.isEmpty, value != "?" {
                extras.append(Column(title: index < titles.count ? titles[index] : "", value: value))
            }
        }
        self.pid = pid
        self.user = user
        self.command = command
        self.extras = extras
    }
}
