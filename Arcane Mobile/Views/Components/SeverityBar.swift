import SwiftUI

/// Horizontal proportional severity breakdown: an 8pt capsule of colored
/// segments (matching `SeverityBadge` colors) with labeled counts beneath.
/// A bar, not a donut — matches the app's progress-bar vocabulary.
struct SeverityBar: View {
    let critical: Int
    let high: Int
    let medium: Int
    let low: Int
    let unknown: Int

    private var segments: [(label: String, count: Int, color: Color)] {
        [
            ("Critical", RemoteDataLimits.nonnegative(critical), .red),
            ("High", RemoteDataLimits.nonnegative(high), .orange),
            ("Med", RemoteDataLimits.nonnegative(medium), .yellow),
            ("Low", RemoteDataLimits.nonnegative(low), .blue),
            ("?", RemoteDataLimits.nonnegative(unknown), .gray),
        ]
    }

    private var total: Int {
        segments.reduce(0) { RemoteDataLimits.saturatingAdd($0, $1.count) }
    }

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                HStack(spacing: total > 0 ? 2 : 0) {
                    if total > 0 {
                        ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                            if segment.count > 0 {
                                Capsule()
                                    .fill(segment.color)
                                    .frame(width: max(6, geo.size.width * CGFloat(segment.count) / CGFloat(total)))
                            }
                        }
                    } else {
                        Capsule().fill(.secondary.opacity(0.15))
                    }
                }
            }
            .frame(height: 8)
            .animation(Motion.gauge, value: total)

            HStack(spacing: 12) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    VStack(spacing: 1) {
                        Text(verbatim: "\(segment.count)")
                            .font(.caption.bold())
                            .foregroundStyle(segment.count > 0 ? segment.color : .secondary)
                            .contentTransition(.numericText())
                            .motionAwareAnimation(Motion.state, value: segment.count)
                        Text(segment.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        guard total > 0 else { return "No vulnerabilities" }
        let parts = segments.filter { $0.count > 0 }.map { "\($0.count) \($0.label)" }
        return "Vulnerabilities: " + parts.joined(separator: ", ")
    }
}
