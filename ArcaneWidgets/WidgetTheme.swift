import SwiftUI
import WidgetKit

/// Widget-local theming helpers. Self-contained on purpose — the app's
/// Extensions/ files are not members of this target, so the hex parser is
/// duplicated here under a distinct name (no symbol clash if that changes).
enum WidgetTheme {
    /// User's accent from the snapshot, falling back to the brand blue.
    static func accent(from snapshot: WidgetSnapshot?) -> Color {
        snapshot?.accentHex.flatMap(color(hex:)) ?? .blue
    }

    static func color(hex: String) -> Color? {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let rgb = UInt64(value, radix: 16) else { return nil }
        return Color(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}

/// Standard widget container background: a whisper of accent gradient in the
/// default rendering mode; plain background in `.accented` (tinted Home
/// Screen) and StandBy, where custom gradients fight the system treatment.
struct WidgetContainerBackground: ViewModifier {
    @Environment(\.widgetRenderingMode) private var renderingMode
    let accent: Color

    func body(content: Content) -> some View {
        content.containerBackground(for: .widget) {
            if renderingMode == .fullColor {
                LinearGradient(
                    colors: [accent.opacity(0.14), .clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            } else {
                Color.clear
            }
        }
    }
}

extension View {
    func widgetContainerBackground(accent: Color) -> some View {
        modifier(WidgetContainerBackground(accent: accent))
    }
}

/// Small status dot that stays legible in tinted/StandBy rendering.
struct StatusDot: View {
    @Environment(\.widgetRenderingMode) private var renderingMode
    let online: Bool

    var body: some View {
        Circle()
            .fill(renderingMode == .fullColor ? (online ? Color.green : Color.red) : Color.primary)
            .opacity(online ? 1 : 0.5)
            .frame(width: 7, height: 7)
            .widgetAccentable()
    }
}

/// Small trailing icon+count chip used consistently across widget rows.
struct WidgetCountChip: View {
    let count: Int
    let systemImage: String
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .semibold))
            Text("\(count)")
                .font(.system(.caption2, design: .rounded).weight(.semibold))
                .monospacedDigit()
        }
        .foregroundStyle(tint)
    }
}

/// Shared empty state when no server is configured.
struct WidgetUnconfiguredView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "server.rack")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Open Arcane to connect a server")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}
