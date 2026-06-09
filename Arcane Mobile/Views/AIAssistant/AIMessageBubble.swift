import SwiftUI

/// One transcript row. User turns sit in an accent-tinted bubble (trailing);
/// assistant replies are plain selectable text (leading, no bubble); system
/// lines (action outcomes) are a small centered pill.
struct AIMessageBubble: View {
    let message: AIMessage

    var body: some View {
        switch message.role {
        case .user: userBubble
        case .assistant: assistantText
        case .system: systemLine
        }
    }

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 56)
            Text(message.text)
                .font(.body)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.tint, in: .rect(cornerRadius: 20, style: .continuous))
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var assistantText: some View {
        if message.text.isEmpty && message.isStreaming {
            HStack {
                ThinkingDots()
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
        } else {
            Text(LocalizedStringKey(message.text))
                .font(.body)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private var systemLine: some View {
        Label(message.text, systemImage: "checkmark.circle.fill")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: .capsule)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

/// Animated three-dot thinking indicator with aurora-tinted colors.
private struct ThinkingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = 0

    private let dotColors: [Color] = [.purple, .pink, .blue]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .frame(width: 7, height: 7)
                    .foregroundStyle(dotColors[i].opacity(0.8))
                    .opacity(reduceMotion ? 0.7 : (phase == i ? 1 : 0.3))
                    .scaleEffect(reduceMotion ? 1 : (phase == i ? 1.2 : 0.8))
            }
        }
        .animation(.spring(duration: 0.3), value: phase)
        .task {
            guard !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                phase = (phase + 1) % 3
            }
        }
        .accessibilityLabel("Thinking")
    }
}
