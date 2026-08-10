import SwiftUI

/// One row of the dashboard's "Needs Attention" section. Built by DashboardView
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

/// Compact triage section between the overview summary and environment rows.
/// Renders only when non-empty — there is deliberately no green "all clear"
/// state; absence is the all-clear.
struct NeedsAttentionSection: View {
    let items: [NeedsAttentionItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Needs Attention")
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.bottom, 6)

            ForEach(items) { item in
                row(item)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
            .padding(.horizontal, 4)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.title): \(item.count)")
        .accessibilityAddTraits(.isButton)
    }
}
