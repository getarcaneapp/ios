import SwiftUI
import Arcane

struct ContainerHealthSection: View {
    let health: ContainerHealth

    var body: some View {
        Section("Health") {
            LabeledContent("Status") {
                Label(health.status.capitalized, systemImage: "heart.fill")
                    .foregroundStyle(statusColor)
            }
            LabeledContent("Failing streak") {
                Text(verbatim: "\(health.failingStreak)").monospacedDigit()
            }
            if let log = health.log, !log.isEmpty {
                NavigationLink(destination: ContainerHealthHistoryView(log: log)) {
                    Label("History (\(log.count))", systemImage: "clock.arrow.circlepath")
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
                            .foregroundStyle(entry.exitCode == 0 ? Color.green : Color.red)
                    }
                    if let output = entry.output, !output.isEmpty {
                        Text(output.trimmingCharacters(in: .whitespacesAndNewlines))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .listStyle(.insetGrouped)
        .softTopScrollEdgeEffectCompat()
        .navigationTitle("Health History")
    }
}

private extension String {
    var formattedHealthDate: String {
        ArcaneDateFormatting.formattedISO8601(self, date: .abbreviated, time: .standard)
    }
}
