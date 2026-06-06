//
//  DeleteConfirmation.swift
//  Arcane Mobile
//
//  A reusable destructive-confirmation surface used app-wide in place of
//  `.alert` / `.confirmationDialog`. It presents a bottom card with a dark
//  scrim and capsule Cancel / action buttons that rises and fades in.
//
//  The card design + spring timing are adapted from Balaji Venkatesh's
//  `AnimatedDeleteButton` sample. The original morphs out of the tapped button
//  via an ImageRenderer snapshot; because most of this app's confirmations fire
//  from swipe actions, context menus, toolbar buttons and `.alert` state (none
//  of which leave a persistent source button), we present the same card as a
//  unified bottom sheet instead — one consistent look for every trigger.
//

import SwiftUI

// MARK: - Public model

/// A single actionable choice in the confirmation card, shown in addition to
/// the built-in Cancel button. Most callers pass exactly one (the destructive
/// action); Projects passes two ("Delete" / "Delete and Remove Files").
struct DeleteConfirmationAction: Identifiable {
    let id = UUID()
    var title: String
    var role: ButtonRole? = .destructive
    /// Capsule fill. Defaults to red for `.destructive`, the app tint otherwise.
    var tint: Color? = nil
    var action: () -> Void

    init(
        title: String,
        role: ButtonRole? = .destructive,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.role = role
        self.tint = tint
        self.action = action
    }
}

struct DeleteConfirmationConfig {
    var title: String
    var message: String? = nil
    /// SF Symbol shown above the title; `nil` hides it.
    var icon: String? = "exclamationmark.triangle"
    var actions: [DeleteConfirmationAction]
    var cancelTitle: String = "Cancel"
}

// MARK: - View modifiers (public API)

extension View {
    /// Bool-driven, single destructive action. Mirrors `.alert(_:isPresented:)`.
    func deleteConfirmation(
        isPresented: Binding<Bool>,
        title: String,
        message: String? = nil,
        icon: String? = "exclamationmark.triangle",
        confirmTitle: String = "Delete",
        confirmTint: Color? = nil,
        onConfirm: @escaping () -> Void
    ) -> some View {
        modifier(DeleteConfirmationBoolModifier(
            isPresented: isPresented,
            config: DeleteConfirmationConfig(
                title: title,
                message: message,
                icon: icon,
                actions: [DeleteConfirmationAction(
                    title: confirmTitle,
                    tint: confirmTint,
                    action: onConfirm
                )]
            )
        ))
    }

    /// Bool-driven, full control over the card (multiple actions, custom cancel).
    func deleteConfirmation(
        isPresented: Binding<Bool>,
        config: DeleteConfirmationConfig
    ) -> some View {
        modifier(DeleteConfirmationBoolModifier(isPresented: isPresented, config: config))
    }

    /// Item-driven, single destructive action. Mirrors
    /// `.alert(_:isPresented:presenting:)` — drive it from a `pending<X>` optional
    /// set by swipe / context-menu / row actions.
    func deleteConfirmation<Item>(
        item: Binding<Item?>,
        title: @escaping (Item) -> String,
        message: @escaping (Item) -> String? = { _ in nil },
        icon: String? = "exclamationmark.triangle",
        confirmTitle: String = "Delete",
        confirmTint: Color? = nil,
        onConfirm: @escaping (Item) -> Void
    ) -> some View {
        modifier(DeleteConfirmationItemModifier(item: item) { value in
            DeleteConfirmationConfig(
                title: title(value),
                message: message(value),
                icon: icon,
                actions: [DeleteConfirmationAction(
                    title: confirmTitle,
                    tint: confirmTint,
                    action: { onConfirm(value) }
                )]
            )
        })
    }

    /// Item-driven, full control over the card.
    func deleteConfirmation<Item>(
        item: Binding<Item?>,
        config: @escaping (Item) -> DeleteConfirmationConfig
    ) -> some View {
        modifier(DeleteConfirmationItemModifier(item: item, configBuilder: config))
    }
}

// MARK: - Modifiers

private struct DeleteConfirmationBoolModifier: ViewModifier {
    @Binding var isPresented: Bool
    let config: DeleteConfirmationConfig

    /// Internal mirror so we control the cover's (suppressed) transition.
    @State private var coverShown = false

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented) { _, presented in
                if presented, !coverShown {
                    withoutAnimation { coverShown = true }
                } else if !presented, coverShown {
                    withoutAnimation { coverShown = false }
                }
            }
            .fullScreenCover(isPresented: $coverShown) {
                DeleteConfirmationCard(config: config) { action in
                    withoutAnimation {
                        coverShown = false
                        isPresented = false
                    }
                    action?()
                }
                .deleteConfirmationCoverChrome()
            }
    }
}

private struct DeleteConfirmationItemModifier<Item>: ViewModifier {
    @Binding var item: Item?
    let configBuilder: (Item) -> DeleteConfirmationConfig

    @State private var coverShown = false
    /// Held across the exit animation so the card keeps its content while the
    /// caller's `item` is cleared.
    @State private var captured: Item?

    func body(content: Content) -> some View {
        content
            // Optional-to-nil comparison needs no Equatable on `Item`.
            .onChange(of: item != nil) { _, hasItem in
                if hasItem {
                    captured = item
                    withoutAnimation { coverShown = true }
                } else if coverShown {
                    withoutAnimation { coverShown = false }
                }
            }
            .fullScreenCover(isPresented: $coverShown) {
                if let captured {
                    DeleteConfirmationCard(config: configBuilder(captured)) { action in
                        withoutAnimation {
                            coverShown = false
                            item = nil
                        }
                        action?()
                        self.captured = nil
                    }
                    .deleteConfirmationCoverChrome()
                }
            }
    }
}

private extension View {
    /// Shared chrome for the confirmation's full-screen cover so the scrim/card
    /// float above the nav and tab bars with no system background of their own.
    func deleteConfirmationCoverChrome() -> some View {
        self
            .ignoresSafeArea()
            .presentationBackground(.clear)
            .persistentSystemOverlays(.hidden)
    }
}

// MARK: - Card

private struct DeleteConfirmationCard: View {
    let config: DeleteConfirmationConfig
    /// Invoked once the exit animation finishes. `action == nil` means cancelled;
    /// otherwise it's the chosen action's closure, run after the card is gone.
    let onResolved: (_ action: (() -> Void)?) -> Void

    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let cornerRadius: CGFloat = 40

    var body: some View {
        ZStack(alignment: .bottom) {
            Rectangle()
                .fill(.black.opacity(shown ? 0.4 : 0))
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { resolve(nil) }

            card
                .frame(maxWidth: 500)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity)
                .offset(y: shown ? 0 : offscreenOffset)
                .opacity(shown ? 1 : 0)
                .blur(radius: shown ? 0 : entranceBlur)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .allowsHitTesting(shown)
        .onAppear {
            HapticsManager.warning()
            withAnimation(entrance) { shown = true }
        }
    }

    private var card: some View {
        VStack(spacing: 16) {
            VStack(spacing: 10) {
                if let icon = config.icon {
                    Image(systemName: icon)
                        .font(.system(size: 32, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.red)
                }
                Text(config.title)
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let message = config.message, !message.isEmpty {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity)

            buttons
        }
        .padding(20)
        .background(.background, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.primary.opacity(0.06), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.2), radius: 18, y: 6)
    }

    @ViewBuilder
    private var buttons: some View {
        if config.actions.count <= 1 {
            HStack(spacing: 8) {
                cancelButton
                ForEach(config.actions) { actionButton($0) }
            }
            .fontWeight(.semibold)
        } else {
            VStack(spacing: 8) {
                ForEach(config.actions) { actionButton($0) }
                cancelButton
            }
            .fontWeight(.semibold)
        }
    }

    private var cancelButton: some View {
        Button { resolve(nil) } label: {
            Text(config.cancelTitle)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(.gray.opacity(0.25), in: .capsule)
        }
        .buttonStyle(.plain)
    }

    private func actionButton(_ action: DeleteConfirmationAction) -> some View {
        let tint = action.tint ?? (action.role == .destructive ? .red : .accentColor)
        return Button { resolve(action.action) } label: {
            Text(action.title)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(tint.gradient, in: .capsule)
        }
        .buttonStyle(.plain)
    }

    private func resolve(_ action: (() -> Void)?) {
        if action != nil { HapticsManager.success() }
        withAnimation(exit, completionCriteria: .removed) {
            shown = false
        } completion: {
            onResolved(action)
        }
    }

    // MARK: Motion

    private var entrance: Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .interpolatingSpring(duration: 0.3)
    }

    private var exit: Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .interpolatingSpring(duration: 0.3)
    }

    private var offscreenOffset: CGFloat { reduceMotion ? 0 : 28 }
    private var entranceBlur: CGFloat { reduceMotion ? 0 : 12 }
}

// MARK: - Helpers

/// Run a state mutation with implicit animations disabled. Used to present /
/// dismiss the full-screen cover instantly so only the card's own animation
/// shows, never the cover's default slide.
private func withoutAnimation(_ body: () -> Void) {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction, body)
}
