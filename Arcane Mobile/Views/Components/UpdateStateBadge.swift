import SwiftUI

struct UpdateStateBadge: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let state: ImageUpdateState

    private var presentation: (title: String, symbol: String, color: Color) {
        switch state {
        case .unknown: ("Not checked", "questionmark.circle", .secondary)
        case .upToDate: ("Up to date", "checkmark.circle.fill", .green)
        case .hasUpdate: ("Update available", "arrow.up.circle.fill", .orange)
        case .error: ("Check failed", "exclamationmark.triangle.fill", .red)
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: presentation.symbol)
                .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
            Text(presentation.title)
                .contentTransition(.opacity)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(presentation.color)
        .lineLimit(1)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(presentation.color.opacity(0.12), in: Capsule())
        .motionAwareAnimation(Motion.state, value: state)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.accessibilityDescription)
    }
}
