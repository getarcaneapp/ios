import SwiftUI

/// Composer bar rendered at the bottom of `AIChatView`.
/// Uses pure local @State for the draft so that typing never touches
/// service.inputDraft and never triggers a re-render of AIChatView.
/// Re-renders of AIChatView were the root cause of repeated focus loss
/// (SwiftUI resets @FocusState when the parent re-evaluates its body).
@available(iOS 26, *)
struct AIComposerBar: View {
    let isResponding: Bool
    let isAvailable: Bool
    let onSend: (String) -> Void
    let onStop: () -> Void

    @FocusState private var focused: Bool
    @State private var draft = ""
    @State private var shimmerPhase: Double = 0

    private var pillShape: RoundedRectangle { .rect(cornerRadius: 22, style: .continuous) }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isResponding
            && isAvailable
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.circle")
                    .font(.caption2)
                Text("Assistant uses AI and can make mistakes.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 20)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .center)

            HStack(alignment: .bottom, spacing: 6) {
                TextField("Message", text: $draft)
                    .focused($focused)
                    .padding(.leading, 16)
                    .padding(.vertical, 10)
                    .submitLabel(.send)
                    .onSubmit { send() }

                Button {
                    if isResponding { onStop() } else { send() }
                } label: {
                    Image(systemName: isResponding ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(buttonTint)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .disabled(!isResponding && !canSend)
                .animation(.easeInOut(duration: 0.15), value: canSend)
                .padding(.trailing, 5)
                .padding(.bottom, 4)
                .accessibilityLabel(isResponding ? "Stop" : "Send")
            }
            .background(.regularMaterial, in: pillShape)
            .overlay {
                ZStack {
                    pillShape.strokeBorder(.primary.opacity(0.07), lineWidth: 0.5)
                    if isResponding {
                        pillShape.strokeBorder(
                            LinearGradient(
                                colors: [.indigo, .purple, .pink, .purple, .indigo],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.5
                        )
                        .hueRotation(.degrees(shimmerPhase))
                        .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.4), value: isResponding)
            }
            .onChange(of: isResponding) { _, responding in
                if responding {
                    withAnimation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true)) {
                        shimmerPhase = 25
                    }
                } else {
                    shimmerPhase = 0
                }
            }
            .shadow(color: .black.opacity(0.1), radius: 8, y: 2)
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 6)
        }
    }

    private func send() {
        guard canSend else { return }
        onSend(draft)
        draft = ""
    }

    private var buttonTint: Color {
        if isResponding { return .secondary }
        return canSend ? .accentColor : Color(.tertiaryLabel)
    }
}
