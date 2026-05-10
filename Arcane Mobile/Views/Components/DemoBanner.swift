import SwiftUI

struct DemoBanner: View {
    @Environment(ArcaneClientManager.self) private var manager

    var body: some View {
        if manager.isDemoActive, let endsAt = manager.demoEndsAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = max(0, endsAt.timeIntervalSince(context.date))
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.tint)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Demo Mode")
                            .font(.caption.weight(.semibold))
                        Text("\(formatRemaining(remaining)) left")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    Spacer(minLength: 8)

                    Button {
                        Task { await manager.endDemo(reason: .userInitiated) }
                    } label: {
                        Text("End demo")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.accentColor)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
                .overlay(
                    Rectangle()
                        .fill(.tint.opacity(0.4))
                        .frame(height: 0.5),
                    alignment: .bottom
                )
            }
        }
    }

    private func formatRemaining(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}
