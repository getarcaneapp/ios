import SwiftUI
import Arcane

struct ContainerHealthSection: View {
    let health: ContainerHealth

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Health", systemImage: "heart.text.square")
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)
                    Text(health.status.capitalized)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                }
                .padding(12)

                Divider().padding(.leading, 12)

                infoRow("Failing streak") {
                    Text(verbatim: "\(health.failingStreak)")
                        .font(.subheadline.monospacedDigit())
                        .multilineTextAlignment(.trailing)
                }

                if let log = health.log, !log.isEmpty {
                    Divider().padding(.leading, 12)
                    NavigationLink(destination: ContainerHealthHistoryView(log: log)) {
                        HStack(spacing: 10) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                            Text("History (\(log.count))")
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.caption2.bold())
                                .foregroundStyle(.secondary.opacity(0.5))
                        }
                        .padding(12)
                        .contentShape(.rect)
                    }
                    .cardRowLinkStyle()
                }
            }
            .dashboardCardBackground(cornerRadius: Radius.standard)
        }
    }

    private func infoRow(_ label: String, @ViewBuilder value: () -> some View) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 16)
            value()
        }
        .padding(12)
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
        ScrollView {
            LazyVStack(spacing: 10) {
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
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .dashboardCardBackground(cornerRadius: Radius.standard)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 16)
        }
        .softTopScrollEdgeEffectCompat()
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Health History")
    }
}

private extension String {
    var formattedHealthDate: String {
        ArcaneDateFormatting.formattedISO8601(self, date: .abbreviated, time: .standard)
    }
}
