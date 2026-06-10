import SwiftUI

struct ResourceStatusBadge: View {
    let status: String?
    let isLive: Bool?

    init(status: String?, isLive: Bool? = nil) {
        self.status = status
        self.isLive = isLive
    }

    private var normalizedStatus: String {
        status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    private var displayText: String {
        let trimmed = status?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return "Unknown" }
        return trimmed.capitalized
    }

    private var live: Bool {
        if let isLive { return isLive }
        return normalizedStatus == "running" || normalizedStatus == "online"
    }

    private var tint: Color {
        if live { return .green }

        switch normalizedStatus {
        case "running", "online", "success", "completed", "done":
            return .green
        case "partial", "partially running":
            return .orange
        case "stopped", "exited", "offline":
            return .red
        case "error", "failed", "unhealthy":
            return .red
        case "paused":
            return .yellow
        default:
            return .secondary
        }
    }

    private var icon: String {
        if live { return "checkmark.circle.fill" }

        switch normalizedStatus {
        case "running", "online", "success", "completed", "done":
            return "checkmark.circle.fill"
        case "partial", "partially running":
            return "circle.lefthalf.filled"
        case "stopped", "exited", "offline":
            return "stop.circle.fill"
        case "error", "failed", "unhealthy":
            return "exclamationmark.circle.fill"
        case "paused":
            return "pause.circle.fill"
        default:
            return "circle.fill"
        }
    }

    /// Drives the implicit cross-fade / symbol morph when status (or liveness)
    /// changes — captures both so a colour-only change still animates.
    private var animationKey: String { "\(normalizedStatus)|\(live)" }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
                .contentTransition(.symbolEffect(.replace))
                .frame(minWidth: 16, minHeight: 16)

            Text(displayText)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(live ? 0.16 : 0.12), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(tint.opacity(live ? 0.28 : 0.18), lineWidth: 0.75)
        }
        .motionAwareAnimation(Motion.state, value: animationKey)
        .accessibilityLabel("\(displayText) status")
    }
}

/// Compact, text-free status indicator for dense list rows:
/// green ▶ running, red ◼ stopped, yellow ⏸ partial/paused, red ⚠ error.
struct StatusIcon: View {
    let status: String?
    var isLive: Bool? = nil

    private var normalized: String {
        status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    private var live: Bool {
        if let isLive { return isLive }
        return normalized == "running" || normalized == "online"
    }

    private var config: (icon: String, color: Color, label: String) {
        if live { return ("play.circle.fill", .green, "Running") }
        switch normalized {
        case "running", "online", "success", "completed", "done":
            return ("play.circle.fill", .green, "Running")
        case "partial", "partially running":
            return ("pause.circle.fill", .yellow, "Partially running")
        case "paused":
            return ("pause.circle.fill", .yellow, "Paused")
        case "stopped", "exited", "offline":
            return ("stop.circle.fill", .red, "Stopped")
        case "error", "failed", "unhealthy", "dead":
            return ("exclamationmark.circle.fill", .red, "Error")
        default:
            return ("circle.fill", .secondary, status?.capitalized ?? "Unknown")
        }
    }

    private var animationKey: String { "\(normalized)|\(live)" }

    var body: some View {
        Image(systemName: config.icon)
            .font(.title3)
            .foregroundStyle(config.color)
            .contentTransition(.symbolEffect(.replace))
            .motionAwareAnimation(Motion.state, value: animationKey)
            .accessibilityLabel("\(config.label) status")
    }
}
