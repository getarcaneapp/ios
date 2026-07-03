import SwiftUI

/// One row of the dashboard's "Needs Attention" card. Built by DashboardView
/// from data it already holds (stream states, folded action items, failed
/// activities) — this view stays dumb and does no fetching.
struct NeedsAttentionItem: Identifiable {
    enum Severity {
        case critical
        case warning

        var tint: Color {
            switch self {
            case .critical: return .red
            case .warning: return .orange
            }
        }
    }

    let id: String
    let severity: Severity
    let icon: String
    let title: String
    let count: Int
    let action: () -> Void
}

/// Compact triage card between the overview tiles and the environment cards.
/// Renders only when non-empty — there is deliberately no green "all clear"
/// state; absence is the all-clear.
struct NeedsAttentionSection: View {
    let items: [NeedsAttentionItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Needs Attention")
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 4)

            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                row(item)
                if index < items.count - 1 {
                    Divider().padding(.leading, 54)
                }
            }
        }
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCardBackground(cornerRadius: Radius.card)
    }

    private func row(_ item: NeedsAttentionItem) -> some View {
        Button(action: item.action) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(item.severity.tint)
                        .frame(width: 28, height: 28)
                    Image(systemName: item.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Text(item.title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("\(item.count)")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(item.severity.tint)
                    .contentTransition(.numericText())
                    .motionAwareAnimation(Motion.state, value: item.count)
                Image(systemName: "chevron.right")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary.opacity(0.5))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        // List-row rule: opacity-only press, no scale.
        .buttonStyle(.pressable(scales: false))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.title): \(item.count)")
        .accessibilityAddTraits(.isButton)
    }
}
