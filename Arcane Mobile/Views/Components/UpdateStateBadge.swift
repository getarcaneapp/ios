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
        .font(.subheadline)
        .foregroundStyle(presentation.color)
        .fixedSize(horizontal: false, vertical: true)
        .motionAwareAnimation(Motion.state, value: state)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.accessibilityDescription)
    }
}
