import WidgetKit
import SwiftUI

/// Phase-3 widget: pending image updates + actionable vulnerabilities across
/// the fleet, with a per-environment breakdown on systemMedium. Deep-links to
/// the Updates tab.
struct UpdatesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "com.getarcaneapp.ios.mobile.updates",
            provider: EnvironmentsProvider()
        ) { entry in
            UpdatesWidgetView(entry: entry)
        }
        .configurationDisplayName("Updates & Vulnerabilities")
        .description("Pending image updates and actionable vulnerabilities.")
        .supportedFamilies([.systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

struct UpdatesWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: EnvironmentsEntry

    private var accent: Color { WidgetTheme.accent(from: entry.snapshot) }
    private var updates: Int { entry.snapshot?.totalUpdates ?? 0 }
    private var vulnerabilities: Int { entry.snapshot?.totalVulnerabilities ?? 0 }

    /// Environments with something to report, worst first.
    private var interesting: [WidgetSnapshot.EnvSummary] {
        (entry.snapshot?.environments ?? [])
            .filter { $0.updatesAvailable > 0 || ($0.actionableVulnerabilities ?? 0) > 0 }
            .sorted {
                ($0.actionableVulnerabilities ?? 0, $0.updatesAvailable)
                    > ($1.actionableVulnerabilities ?? 0, $1.updatesAvailable)
            }
    }

    var body: some View {
        Group {
            if entry.snapshot?.serverConfigured == true {
                configured
            } else {
                WidgetUnconfiguredView()
            }
        }
        .widgetContainerBackground(accent: accent)
        .widgetURL(URL(string: "arcane-mobile://open?tab=updates"))
    }

    @ViewBuilder
    private var configured: some View {
        switch family {
        case .accessoryInline:
            Text("\(updates) updates · \(vulnerabilities) CVEs")
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Text("Arcane").font(.headline)
                Text("\(updates) update\(updates == 1 ? "" : "s") pending")
                    .font(.caption2)
                Text("\(vulnerabilities) actionable CVE\(vulnerabilities == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        default:
            HStack(spacing: 14) {
                // Totals column fills the widget height, stats spread evenly.
                VStack(alignment: .leading, spacing: 0) {
                    totalBlock(
                        count: updates,
                        label: "Updates",
                        icon: "arrow.triangle.2.circlepath",
                        tint: accent
                    )
                    .frame(maxHeight: .infinity, alignment: .leading)
                    totalBlock(
                        count: vulnerabilities,
                        label: "Vulnerabilities",
                        icon: "exclamationmark.shield.fill",
                        tint: vulnerabilities > 0 ? .orange : .secondary
                    )
                    .frame(maxHeight: .infinity, alignment: .leading)
                }
                .frame(width: 108, alignment: .leading)

                Divider()

                // Environment breakdown, rows spread to fill.
                if interesting.isEmpty {
                    Label("All up to date", systemImage: "checkmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(interesting.prefix(4))) { env in
                            HStack(spacing: 8) {
                                Text(env.name)
                                    .font(.footnote.weight(.medium))
                                    .lineLimit(1)
                                Spacer(minLength: 6)
                                if env.updatesAvailable > 0 {
                                    WidgetCountChip(
                                        count: env.updatesAvailable,
                                        systemImage: "arrow.triangle.2.circlepath",
                                        tint: accent
                                    )
                                    .widgetAccentable()
                                }
                                if let vulns = env.actionableVulnerabilities, vulns > 0 {
                                    WidgetCountChip(
                                        count: vulns,
                                        systemImage: "exclamationmark.shield.fill",
                                        tint: .orange
                                    )
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func totalBlock(count: Int, label: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                Text("\(count)")
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .widgetAccentable()
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
