import WidgetKit
import SwiftUI

struct EnvironmentsEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
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

struct EnvironmentsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "com.getarcaneapp.ios.mobile.environments",
            provider: EnvironmentsProvider()
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
    private var environments: [WidgetSnapshot.EnvSummary] {
        Array((entry.snapshot?.environments ?? []).prefix(4))
    }

    var body: some View {
        Group {
            if entry.snapshot?.serverConfigured == true {
                if environments.isEmpty {
                    Text("No environments")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(environments) { env in
                            Link(destination: deepLink(for: env)) {
                                row(env)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        HStack(spacing: 8) {
            StatusDot(online: env.online)
            Text(env.name)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            Spacer(minLength: 8)
            if env.updatesAvailable > 0 {
                Label("\(env.updatesAvailable)", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(env.online ? "\(env.running)/\(env.total)" : "offline")
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(env.online ? AnyShapeStyle(accent) : AnyShapeStyle(.secondary))
                .widgetAccentable()
        }
    }
}
