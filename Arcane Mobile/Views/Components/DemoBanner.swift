import SwiftUI

struct DemoBanner: View {
    @Environment(ArcaneClientManager.self) private var manager
    @AppStorage("accentColorHex") private var accentColorHex: String = ""

    private var brandColor: Color {
        if let custom = Color(hex: accentColorHex) {
            return custom
        }
        return .accentColor
    }

    var body: some View {
        if manager.isDemoActive, let endsAt = manager.demoEndsAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = max(0, endsAt.timeIntervalSince(context.date))
                let isLowTime = remaining < 60

                HStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(brandColor)
                        .frame(width: 28, height: 28)
                        .background(brandColor.opacity(0.12), in: .circle)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Demo Mode")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("\(formatRemaining(remaining)) remaining")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(isLowTime ? .orange : .secondary)
                            .contentTransition(.numericText(countsDown: true))
                    }

                    Spacer(minLength: 8)

                    Button {
                        Task { await manager.endDemo(reason: .userInitiated) }
                    } label: {
                        Text("End")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .foregroundStyle(brandColor)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.tint(brandColor.opacity(0.18)), in: .capsule)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .rect(cornerRadius: 22))
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 4)
                .animation(.smooth(duration: 0.4), value: isLowTime)
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
