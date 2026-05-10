import ActivityKit
import WidgetKit
import SwiftUI

struct ArcaneDemoWidgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ArcaneDemoWidgetAttributes.self) { context in
            // Lock Screen / banner
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.tint)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Arcane Demo")
                            .font(.subheadline.weight(.semibold))
                        Text("Temporary instance")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text(timerInterval: Date()...context.state.endsAt, countsDown: true)
                        .font(.title2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.tint)
                        .frame(minWidth: 60, alignment: .trailing)
                }

                ProgressView(timerInterval: context.state.startedAt...context.state.endsAt, countsDown: true)
                    .tint(Color.accentColor)

                Link(destination: endDemoURL) {
                    Text("End demo")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(Color.accentColor, in: .capsule)
                        .foregroundStyle(.white)
                }
            }
            .padding(16)
            .activitySystemActionForegroundColor(.primary)

        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.tint)
                            .frame(width: 28, height: 28)
                            .background(Color.accentColor.opacity(0.15), in: .circle)

                        VStack(alignment: .leading, spacing: 0) {
                            Text("Arcane")
                                .font(.subheadline.weight(.semibold))
                            Text("Demo Mode")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.leading, 4)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: Date()...context.state.endsAt, countsDown: true)
                        .font(.title2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.tint)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, 4)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 10) {
                        ProgressView(
                            timerInterval: context.state.startedAt...context.state.endsAt,
                            countsDown: true,
                            label: { EmptyView() },
                            currentValueLabel: { EmptyView() }
                        )
                        .tint(Color.accentColor)

                        Link(destination: endDemoURL) {
                            Text("End demo")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(Color.accentColor.opacity(0.22), in: .capsule)
                                .foregroundStyle(.tint)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 2)
                }
            } compactLeading: {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tint)
            } compactTrailing: {
                Text(timerInterval: Date()...context.state.endsAt, countsDown: true)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .frame(maxWidth: 50)
                    .foregroundStyle(.tint)
            } minimal: {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tint)
            }
            .widgetURL(URL(string: "arcane-mobile://demo"))
        }
    }

    private var endDemoURL: URL {
        URL(string: "arcane-mobile://end-demo")!
    }
}

#Preview("Live Activity",
         as: .content,
         using: ArcaneDemoWidgetAttributes()) {
    ArcaneDemoWidgetLiveActivity()
} contentStates: {
    ArcaneDemoWidgetAttributes.ContentState(
        startedAt: Date().addingTimeInterval(-60),
        endsAt: Date().addingTimeInterval(540)
    )
    ArcaneDemoWidgetAttributes.ContentState(
        startedAt: Date().addingTimeInterval(-540),
        endsAt: Date().addingTimeInterval(60)
    )
}
