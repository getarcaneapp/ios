//
//  DeployLiveActivity.swift
//  ArcaneWidgets
//
//  Live Activity presentations for deploy/redeploy/pull/build operations.
//  Renders in the Dynamic Island on hardware that has one and as a Lock
//  Screen banner everywhere else — the app never does device detection.
//  Visuals stay restrained: system fonts, semantic tints, no glow.
//

import ActivityKit
import SwiftUI
import WidgetKit

struct DeployLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DeployActivityAttributes.self) { context in
            LockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ExpandedIcon(context: context)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            // Keep the tail visible — for image pulls the tag
                            // is the interesting part.
                            .truncationMode(.middle)
                        Text(phaseText(for: context.state, isStale: context.isStale))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ExpandedBottom(context: context)
                }
            } compactLeading: {
                Image(systemName: compactSymbol(for: context))
                    .foregroundStyle(stateTint(for: context.state))
            } compactTrailing: {
                CompactTrailing(state: context.state)
            } minimal: {
                MinimalView(state: context.state)
            }
            .keylineTint(stateTint(for: context.state))
        }
    }
}

// MARK: - Lock Screen / banner

private struct LockScreenView: View {
    let context: ActivityViewContext<DeployActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: symbolName(for: context))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(stateTint(for: context.state))
                    .frame(width: 36, height: 36)
                    .background(
                        stateTint(for: context.state).opacity(0.15),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(phaseText(for: context.state, isStale: context.isStale))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                TrailingIndicator(state: context.state)
            }

            if context.state.state == .running, let progress = context.state.progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(stateTint(for: context.state))
            }

            Text(context.attributes.environmentName)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(14)
        .activityBackgroundTint(nil)
    }
}

// MARK: - Dynamic Island pieces

private struct ExpandedIcon: View {
    let context: ActivityViewContext<DeployActivityAttributes>

    var body: some View {
        Image(systemName: symbolName(for: context))
            .font(.title3.weight(.semibold))
            .foregroundStyle(stateTint(for: context.state))
            .frame(maxHeight: .infinity, alignment: .center)
    }
}

private struct ExpandedBottom: View {
    let context: ActivityViewContext<DeployActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if context.state.state == .running, let progress = context.state.progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(stateTint(for: context.state))
            }
            HStack {
                Text(context.attributes.environmentName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if context.state.state == .running, let progress = context.state.progress {
                    Text("\(Int(progress * 100))%")
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        // The bottom region spans the island's full width, so unpadded
        // content runs under the curved corners and gets visually clipped.
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }
}

private struct CompactTrailing: View {
    let state: DeployActivityAttributes.ContentState

    var body: some View {
        switch state.state {
        case .running:
            if let progress = state.progress {
                ProgressRing(fraction: progress, tint: stateTint(for: state))
            } else {
                Image(systemName: "ellipsis")
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .success:
            Image(systemName: "checkmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(.green)
        case .failure:
            Image(systemName: "xmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(.red)
        }
    }
}

private struct MinimalView: View {
    let state: DeployActivityAttributes.ContentState

    var body: some View {
        switch state.state {
        case .running:
            if let progress = state.progress {
                ProgressRing(fraction: progress, tint: stateTint(for: state))
            } else {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.blue)
            }
        case .success:
            Image(systemName: "checkmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(.green)
        case .failure:
            Image(systemName: "xmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(.red)
        }
    }
}

/// Small determinate ring for the compact/minimal island slots.
private struct ProgressRing: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(.tertiary, lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 16, height: 16)
    }
}

private struct TrailingIndicator: View {
    let state: DeployActivityAttributes.ContentState

    var body: some View {
        switch state.state {
        case .running:
            if let progress = state.progress {
                Text("\(Int(progress * 100))%")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)
        case .failure:
            Image(systemName: "xmark.octagon.fill")
                .font(.title3)
                .foregroundStyle(.red)
        }
    }
}

// MARK: - Shared helpers

private func stateTint(for state: DeployActivityAttributes.ContentState,
                       isStale: Bool = false) -> Color {
    if isStale, state.state == .running { return .gray }
    switch state.state {
    case .running: return .blue
    case .success: return .green
    case .failure: return .red
    }
}

/// A stale running activity means the app was suspended mid-operation and
/// can't push updates — say so instead of freezing on the last phase.
private func phaseText(for state: DeployActivityAttributes.ContentState,
                       isStale: Bool = false) -> String {
    if isStale, state.state == .running { return "Open Arcane to update" }
    return state.state == .running ? "\(state.phase)…" : state.phase
}

private func symbolName(for context: ActivityViewContext<DeployActivityAttributes>) -> String {
    switch context.state.state {
    case .running: context.attributes.symbolName
    case .success: "checkmark.circle.fill"
    case .failure: "xmark.octagon.fill"
    }
}

private func compactSymbol(for context: ActivityViewContext<DeployActivityAttributes>) -> String {
    context.attributes.symbolName
}
