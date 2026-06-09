import SwiftUI

/// The chat surface: a clean scrolling transcript with inline confirmation
/// cards, a centered welcome/empty state, and the bottom composer.
///
/// `AIComposerBar` is placed in a plain `VStack` rather than `safeAreaInset` so
/// it shares the same UIKit hosting context as the scroll view. Using
/// `safeAreaInset` put the composer in a separate UIKit window that the keyboard
/// treated as a "different screen", which caused typing to break after one char.
@available(iOS 26, *)
struct AIChatView: View {
    @Bindable var service: AIAssistantService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let bottomID = "ai-bottom"

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if let banner = service.contextBanner {
                            contextBanner(banner)
                        }

                        if service.messages.isEmpty {
                            welcome
                            suggestions
                        }

                        ForEach(service.messages) { message in
                            AIMessageBubble(message: message)
                                .id(message.id)
                        }

                        ForEach(service.visibleActions) { action in
                            AIActionConfirmationCard(
                                action: action,
                                onConfirm: { service.requestConfirm(action) },
                                onCancel: { service.cancel(action.id) }
                            )
                            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                        }

                        Color.clear.frame(height: 1).id(bottomID)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                }
                .softTopScrollEdgeEffectCompat()
                .scrollDismissesKeyboard(.interactively)
                .animation(reduceMotion ? nil : Motion.state, value: service.visibleActions.count)
                .onChange(of: service.messages.count) { _, _ in
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                        proxy.scrollTo(bottomID, anchor: .bottom)
                    }
                }
            }

            AIComposerBar(
                isResponding: service.isResponding,
                isAvailable: service.availability == .available,
                onSend: { service.send($0) },
                onStop: { service.stop() }
            )
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    service.clearConversation()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .disabled(service.messages.isEmpty && service.visibleActions.isEmpty)
                .accessibilityLabel("New conversation")
            }
        }
        .deleteConfirmation(
            item: $service.destructiveConfirm,
            title: { $0.confirmationTitle },
            message: { _ in "The assistant proposed this. It runs immediately and can't be undone." },
            confirmTitle: "Confirm",
            confirmTint: .red,
            onConfirm: { action in service.executeConfirmed(action) }
        )
    }

    // MARK: - Empty state

    private var welcome: some View {
        VStack(spacing: 20) {
            ArcaneAssistantIcon(size: 72)

            VStack(spacing: 6) {
                Text("Arcane Assistant")
                    .font(.title2.weight(.semibold))
                Text("Ask about this environment — check container status, review logs, and run actions you confirm. Everything stays on-device.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 32)
        .padding(.bottom, 8)
    }

    private var suggestions: some View {
        VStack(spacing: 8) {
            ForEach(starterPrompts, id: \.text) { prompt in
                Button {
                    service.inputDraft = prompt.text
                    service.send()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: prompt.icon)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(.tint, in: .circle)

                        Text(prompt.text)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)

                        Spacer(minLength: 0)

                        Image(systemName: "arrow.up")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var starterPrompts: [(icon: String, text: String)] {
        [
            ("play.circle", "What's running right now?"),
            ("exclamationmark.triangle", "Any containers that aren't running?"),
            ("square.stack.3d.up", "Summarize my Compose projects")
        ]
    }

    private func contextBanner(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "link")
                .font(.caption2.weight(.semibold))
            Text(text)
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: .capsule)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - Arcane Assistant Icon

/// Aurora gradient icon used in the welcome state and loading screens.
/// Gently oscillates between indigo-purple and purple-pink — a subtle Apple
/// Intelligence-style shimmer rather than a full hue spin.
struct ArcaneAssistantIcon: View {
    var size: CGFloat = 72
    @State private var shifted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            LinearGradient(
                colors: shifted
                    ? [Color(hue: 0.82, saturation: 0.7, brightness: 0.9),   // soft pink-purple
                       Color(hue: 0.75, saturation: 0.8, brightness: 0.8),   // medium purple
                       Color(hue: 0.68, saturation: 0.75, brightness: 0.75)] // indigo
                    : [Color(hue: 0.77, saturation: 0.75, brightness: 0.85),  // purple
                       Color(hue: 0.83, saturation: 0.65, brightness: 0.88),  // pink-purple
                       Color(hue: 0.72, saturation: 0.7, brightness: 0.8)],  // blue-purple
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .clipShape(.circle)
            .frame(width: size, height: size)
            .shadow(color: Color(hue: 0.78, saturation: 0.7, brightness: 0.7).opacity(0.45),
                    radius: size * 0.28, y: 4)

            Image(systemName: "sparkles")
                .font(.system(size: size * 0.42, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 3.5).repeatForever(autoreverses: true)) {
                shifted = true
            }
        }
    }
}
