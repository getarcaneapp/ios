import SwiftUI
import Arcane

struct ContainerHealthSection: View {
    let health: ContainerHealth

    var body: some View {
        Section("Health") {
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text(health.status.capitalized)
                    .font(.body)
                Spacer()
            }

            LabeledContent("Failing streak", value: "\(health.failingStreak)")

            if let log = health.log, !log.isEmpty {
                NavigationLink("History (\(log.count))") {
                    ContainerHealthHistoryView(log: log)
                }
            }
        }
    }

    private var statusColor: Color {
        switch health.status.lowercased() {
        case "healthy": return .green
        case "unhealthy": return .red
        case "starting": return .orange
        default: return .secondary
        }
    }
}

struct ContainerHealthHistoryView: View {
    let log: [ContainerHealthLogEntry]

    var body: some View {
        List {
            ForEach(Array(log.enumerated()), id: \.offset) { _, entry in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(entry.start?.formattedHealthDate ?? "—")
                            .font(.caption.bold())
                        if let end = entry.end?.formattedHealthDate {
                            Text("→ \(end)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("exit \(entry.exitCode)")
                            .font(.caption.monospaced())
                            .padding(.vertical, 2)
                            .padding(.horizontal, 6)
                            .background(entry.exitCode == 0 ? Color.green.opacity(0.2) : Color.red.opacity(0.2),
                                        in: .capsule)
                            .foregroundStyle(entry.exitCode == 0 ? Color.green : Color.red)
                    }
                    if let output = entry.output, !output.isEmpty {
                        Text(output.trimmingCharacters(in: .whitespacesAndNewlines))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(6)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Health History")
    }
}

private extension String {
    var formattedHealthDate: String {
        ArcaneDateFormatting.formattedISO8601(self, date: .abbreviated, time: .standard)
    }
}
