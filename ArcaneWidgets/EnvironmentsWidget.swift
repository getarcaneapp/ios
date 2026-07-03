import WidgetKit
import SwiftUI
import AppIntents

struct EnvironmentsEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
    /// User-picked environment IDs (ordered); nil/empty = first 4.
    var selectedIDs: [String] = []
}

struct EnvironmentsProvider: TimelineProvider {
    func placeholder(in context: Context) -> EnvironmentsEntry {
        EnvironmentsEntry(date: Date(), snapshot: StatusEntry.placeholderEntry().snapshot)
    }

    func getSnapshot(in context: Context, completion: @escaping (EnvironmentsEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
        } else {
            completion(EnvironmentsEntry(date: Date(), snapshot: WidgetSnapshotStore.load()))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<EnvironmentsEntry>) -> Void) {
        let entry = EnvironmentsEntry(date: Date(), snapshot: WidgetSnapshotStore.load())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(30 * 60))))
    }
}

// MARK: - Configuration (pick up to 4 environments)

struct EnvironmentsWidgetConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Environments"
    static let description = IntentDescription("Pick up to 4 environments to show; leave empty for the first 4.")

    @Parameter(title: "Environments", size: 4)
    var environments: [EnvironmentEntity]?
}

struct ConfiguredEnvironmentsProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> EnvironmentsEntry {
        EnvironmentsEntry(date: Date(), snapshot: StatusEntry.placeholderEntry().snapshot)
    }

    func snapshot(for configuration: EnvironmentsWidgetConfigurationIntent, in context: Context) async -> EnvironmentsEntry {
        if context.isPreview { return placeholder(in: context) }
        return entry(for: configuration)
    }

    func timeline(for configuration: EnvironmentsWidgetConfigurationIntent, in context: Context) async -> Timeline<EnvironmentsEntry> {
        Timeline(entries: [entry(for: configuration)], policy: .after(Date().addingTimeInterval(30 * 60)))
    }

    private func entry(for configuration: EnvironmentsWidgetConfigurationIntent) -> EnvironmentsEntry {
        EnvironmentsEntry(
            date: Date(),
            snapshot: WidgetSnapshotStore.load(),
            selectedIDs: (configuration.environments ?? []).map(\.id)
        )
    }
}

struct EnvironmentsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: "com.getarcaneapp.ios.mobile.environments",
            intent: EnvironmentsWidgetConfigurationIntent.self,
            provider: ConfiguredEnvironmentsProvider()
        ) { entry in
            EnvironmentsWidgetView(entry: entry)
        }
        .configurationDisplayName("Environments")
        .description("Container counts across your environments.")
        .supportedFamilies([.systemMedium])
    }
}

struct EnvironmentsWidgetView: View {
    let entry: EnvironmentsEntry

    private var accent: Color { WidgetTheme.accent(from: entry.snapshot) }

    /// The user's picked environments in their picked order, capped at 4;
    /// no selection = the snapshot's first 4.
    private var environments: [WidgetSnapshot.EnvSummary] {
        let all = entry.snapshot?.environments ?? []
        guard !entry.selectedIDs.isEmpty else { return Array(all.prefix(4)) }
        return Array(entry.selectedIDs.compactMap { id in all.first(where: { $0.id == id }) }.prefix(4))
    }

    var body: some View {
        Group {
            if entry.snapshot?.serverConfigured == true {
                if environments.isEmpty {
                    Text("No environments")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    // Rows spread evenly so the widget is filled no matter
                    // how many environments exist.
                    VStack(spacing: 0) {
                        ForEach(environments) { env in
                            Link(destination: deepLink(for: env)) {
                                row(env)
                            }
                            .frame(maxHeight: .infinity)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                WidgetUnconfiguredView()
            }
        }
        .widgetContainerBackground(accent: accent)
    }

    private func deepLink(for env: WidgetSnapshot.EnvSummary) -> URL {
        URL(string: "arcane-mobile://open?tab=containers&env=\(env.id)")
            ?? URL(string: "arcane-mobile://open")!
    }

    private func row(_ env: WidgetSnapshot.EnvSummary) -> some View {
        HStack(spacing: 10) {
            StatusDot(online: env.online)
            Text(env.name)
                .font(.footnote.weight(.medium))
                .lineLimit(1)
            Spacer(minLength: 8)
            if env.updatesAvailable > 0 {
                WidgetCountChip(
                    count: env.updatesAvailable,
                    systemImage: "arrow.triangle.2.circlepath",
                    tint: .secondary
                )
            }
            Text(env.online ? "\(env.running)/\(env.total)" : "offline")
                .font(.system(.footnote, design: .rounded).weight(.bold))
                .monospacedDigit()
                .foregroundStyle(env.online ? AnyShapeStyle(accent) : AnyShapeStyle(.secondary))
                .widgetAccentable()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
