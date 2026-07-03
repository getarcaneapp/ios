import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Environment entity (configuration)

struct EnvironmentEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Environment"
    static let defaultQuery = EnvironmentEntityQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

/// Reads the App-Group snapshot only — no network in the query path.
struct EnvironmentEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [EnvironmentEntity] {
        let environments = WidgetSnapshotStore.load()?.environments ?? []
        return environments
            .filter { identifiers.contains($0.id) }
            .map { EnvironmentEntity(id: $0.id, name: $0.name) }
    }

    func suggestedEntities() async throws -> [EnvironmentEntity] {
        (WidgetSnapshotStore.load()?.environments ?? [])
            .map { EnvironmentEntity(id: $0.id, name: $0.name) }
    }

    /// Nil default = aggregate across all environments.
    func defaultResult() async -> EnvironmentEntity? { nil }
}

struct StatusWidgetConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Arcane Status"
    static let description = IntentDescription("Choose an environment, or leave empty for your whole fleet.")

    @Parameter(title: "Environment")
    var environment: EnvironmentEntity?
}

// MARK: - Timeline

struct StatusEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
    /// Nil = aggregate.
    let environmentID: String?

    static func placeholderEntry() -> StatusEntry {
        StatusEntry(
            date: Date(),
            snapshot: WidgetSnapshot(
                generatedAt: Date(),
                serverConfigured: true,
                isDemo: false,
                accentHex: nil,
                activeEnvironmentID: "0",
                environments: [
                    .init(id: "0", name: "Local Docker", online: true,
                          running: 12, stopped: 2, total: 14, images: 31,
                          updatesAvailable: 3, actionableVulnerabilities: 5)
                ],
                suggestedContainers: []
            ),
            environmentID: nil
        )
    }
}

struct StatusProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> StatusEntry {
        .placeholderEntry()
    }

    func snapshot(for configuration: StatusWidgetConfigurationIntent, in context: Context) async -> StatusEntry {
        if context.isPreview { return .placeholderEntry() }
        return StatusEntry(
            date: Date(),
            snapshot: WidgetSnapshotStore.load(),
            environmentID: configuration.environment?.id
        )
    }

    func timeline(for configuration: StatusWidgetConfigurationIntent, in context: Context) async -> Timeline<StatusEntry> {
        // Single entry; the app rewrites the snapshot and reloads timelines on
        // material changes. The .after policy is just a staleness backstop.
        let entry = StatusEntry(
            date: Date(),
            snapshot: WidgetSnapshotStore.load(),
            environmentID: configuration.environment?.id
        )
        return Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(30 * 60)))
    }
}

// MARK: - Widget

struct StatusWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: "com.getarcaneapp.ios.mobile.status",
            intent: StatusWidgetConfigurationIntent.self,
            provider: StatusProvider()
        ) { entry in
            StatusWidgetView(entry: entry)
        }
        .configurationDisplayName("Status")
        .description("Container status for an environment or your whole fleet.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct StatusWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: StatusEntry

    private var accent: Color { WidgetTheme.accent(from: entry.snapshot) }

    /// Scoped environment, or nil for aggregate.
    private var scoped: WidgetSnapshot.EnvSummary? {
        guard let id = entry.environmentID else { return nil }
        return entry.snapshot?.environments.first(where: { $0.id == id })
    }

    private var title: String { scoped?.name ?? "All Environments" }
    private var running: Int { scoped?.running ?? entry.snapshot?.totalRunning ?? 0 }
    private var total: Int { scoped?.total ?? entry.snapshot?.totalContainers ?? 0 }
    private var updates: Int { scoped?.updatesAvailable ?? entry.snapshot?.totalUpdates ?? 0 }
    private var online: Bool {
        if let scoped { return scoped.online }
        let snapshot = entry.snapshot
        return (snapshot?.onlineEnvironments ?? 0) > 0
    }

    private var deepLinkURL: URL? {
        var link = "arcane-mobile://open?tab=containers"
        if let id = entry.environmentID { link += "&env=\(id)" }
        return URL(string: link)
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
        .widgetURL(deepLinkURL)
    }

    @ViewBuilder
    private var configured: some View {
        switch family {
        case .accessoryCircular:
            Gauge(value: total > 0 ? Double(running) / Double(total) : 0) {
                Text("CTR")
            } currentValueLabel: {
                Text("\(running)")
            }
            .gaugeStyle(.accessoryCircular)
        case .accessoryInline:
            Text("\(running)/\(total) running")
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    StatusDot(online: online)
                    Text(title).font(.headline).lineLimit(1)
                }
                Text("\(running) of \(total) running")
                    .font(.caption2)
                if updates > 0 {
                    Text("\(updates) update\(updates == 1 ? "" : "s") available")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        default:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    StatusDot(online: online)
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 4)
                    Button(intent: RefreshDashboardIntent()) {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
                Text("\(running)")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(accent)
                    .widgetAccentable()
                Text("of \(total) running")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if updates > 0 {
                    Label("\(updates) updates", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}
