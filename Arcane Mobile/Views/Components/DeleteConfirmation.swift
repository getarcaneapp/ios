//
//  DeleteConfirmation.swift
//  Arcane Mobile
//
//  A reusable destructive-confirmation surface used app-wide in place of
//  `.alert` / `.confirmationDialog`. It shows a centered "card" with a dark scrim
//  and Cancel / action capsule buttons that scales and fades in.
//
//  The card design + spring timing are adapted from Balaji Venkatesh's
//  `AnimatedDeleteButton` sample. The original morphs out of the tapped button;
//  because most of this app's confirmations fire from swipe actions, context
//  menus, toolbar buttons and `.alert` state (none of which leave a persistent
//  source button), we present the same card as a unified centered dialog instead.
//
//  IMPORTANT: the card is rendered by a SINGLE host (`.deleteConfirmationHost()`,
//  mounted once near the app root) as a plain ZStack overlay — NOT via
//  `.fullScreenCover`. A clear-background `fullScreenCover` is unreliable here:
//  dismissing it can leave the screen stuck on a black cover. A root overlay has
//  no cover to leave behind, so it presents and dismisses cleanly every time.
//  `.deleteConfirmation(...)` call sites just publish a request to the host.
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

// MARK: - Presenter (single source of truth)

/// App-wide store for the currently-presented confirmation. `.deleteConfirmation`
/// modifiers publish here; the host (`DeleteConfirmationHost`) renders it.
@MainActor
@Observable
final class DeleteConfirmationPresenter {
    static let shared = DeleteConfirmationPresenter()
    private init() {}

    struct Request: Identifiable {
        let id = UUID()
        let sourceHostID: UUID
        var config: DeleteConfirmationConfig
        var onConfirmDismiss: () -> Void
        /// Resets the source binding (`isPresented = false` / `item = nil`) once
        /// the card is gone, so the trigger can fire again.
        var onDismiss: () -> Void
    }

    private(set) var request: Request?

    func present(
        _ config: DeleteConfirmationConfig,
        sourceHostID: UUID,
        onConfirmDismiss: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        // Defensively retire anything already showing (shouldn't normally happen
        // since the card is modal) so we never strand a binding stuck "on".
        request?.onDismiss()
        request = Request(
            sourceHostID: sourceHostID,
            config: config,
            onConfirmDismiss: onConfirmDismiss,
            onDismiss: onDismiss
        )
    }

    /// Called by the host once the card has animated out.
    func clear() {
        let onDismiss = request?.onDismiss
        request = nil
        onDismiss?()
    }
}

// MARK: - Host (mount once near the root)

extension View {
    /// Mounts the single, app-wide confirmation overlay. Apply once near the
    /// root (above the tab bar / navigation stacks).
    func deleteConfirmationHost() -> some View {
        overlay { DeleteConfirmationHost(hostID: UUID()) }
    }
}

private struct DeleteConfirmationHost: View {
    let hostID: UUID
    @State private var presenter = DeleteConfirmationPresenter.shared

    var body: some View {
        ZStack {
            if let request = presenter.request, request.sourceHostID == hostID {
                DeleteConfirmationCard(config: request.config) { action in
                    action?()
                    if action != nil {
                        request.onConfirmDismiss()
                    }
                    presenter.clear()
                }
                // Fresh identity per request so the card's entrance `onAppear`
                // runs every time it's shown.
                .id(request.id)
                .transition(.identity)
            }
        }
        .allowsHitTesting(presenter.request != nil)
    }
}

// MARK: - View modifiers (public API — call sites are unchanged)

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
        deleteConfirmation(
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
        )
    }

    /// Bool-driven, full control over the card (multiple actions, custom cancel).
    func deleteConfirmation(
        isPresented: Binding<Bool>,
        config: DeleteConfirmationConfig
    ) -> some View {
        modifier(DeleteConfirmationBoolPublisher(isPresented: isPresented, config: config))
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
        deleteConfirmation(item: item) { value in
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
        }
    }

    /// Item-driven, full control over the card.
    func deleteConfirmation<Item>(
        item: Binding<Item?>,
        config: @escaping (Item) -> DeleteConfirmationConfig
    ) -> some View {
        modifier(DeleteConfirmationItemPublisher(item: item, configBuilder: config))
    }
}

private struct DeleteConfirmationBoolPublisher: ViewModifier {
    @Binding var isPresented: Bool
    let config: DeleteConfirmationConfig
    @State private var hostID = UUID()
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content
            .overlay { DeleteConfirmationHost(hostID: hostID) }
            .onChange(of: isPresented) { _, now in
                guard now else { return }
                DeleteConfirmationPresenter.shared.present(
                    config,
                    sourceHostID: hostID,
                    onConfirmDismiss: { dismiss() },
                    onDismiss: {
                        if isPresented { isPresented = false }
                    }
                )
            }
    }
}

private struct DeleteConfirmationItemPublisher<Item>: ViewModifier {
    @Binding var item: Item?
    let configBuilder: (Item) -> DeleteConfirmationConfig
    @State private var hostID = UUID()
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        // Optional-to-nil comparison needs no Equatable on `Item`.
        content
            .overlay { DeleteConfirmationHost(hostID: hostID) }
            .onChange(of: item != nil) { _, hasItem in
                guard hasItem, let value = item else { return }
                DeleteConfirmationPresenter.shared.present(
                    configBuilder(value),
                    sourceHostID: hostID,
                    onConfirmDismiss: { dismiss() },
                    onDismiss: {
                        if item != nil { item = nil }
                    }
                )
            }
    }
}

// MARK: - Card

private struct DeleteConfirmationCard: View {
    let config: DeleteConfirmationConfig
    /// Invoked once the exit animation finishes. `action == nil` means cancelled;
    /// otherwise it's the chosen action's closure, run after the card is gone.
    let onResolved: (_ action: (() -> Void)?) -> Void

    @State private var shown = false
    @State private var isDismissing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let cornerRadius: CGFloat = 40

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(shown ? 0.4 : 0))
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { resolve(nil) }

            // Centered in the screen so it clears the floating tab / action bar
            // on every page — including the compact custom nav bar, where a
            // bottom-anchored card was being clipped.
            card
                .frame(maxWidth: 500)
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity)
                .scaleEffect(shown ? 1 : entranceScale)
                .opacity(shown ? 1 : 0)
                .blur(radius: shown ? 0 : entranceBlur)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
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

    @ViewBuilder
    private var cancelButton: some View {
        if #available(iOS 26, *) {
            // Liquid Glass neutral button.
            Button { resolve(nil) } label: {
                Text(config.cancelTitle)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
        } else {
            Button { resolve(nil) } label: {
                Text(config.cancelTitle)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(.gray.opacity(0.25), in: .capsule)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func actionButton(_ action: DeleteConfirmationAction) -> some View {
        let tint = action.tint ?? (action.role == .destructive ? .red : .accentColor)
        if #available(iOS 26, *) {
            // Prominent Liquid Glass tinted with the action's color.
            Button { resolve(action.action) } label: {
                Text(action.title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .tint(tint)
        } else {
            Button { resolve(action.action) } label: {
                Text(action.title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(tint.gradient, in: .capsule)
            }
            .buttonStyle(.plain)
        }
    }

    private func resolve(_ action: (() -> Void)?) {
        guard !isDismissing else { return }
        isDismissing = true
        if action != nil { HapticsManager.success() }
        withAnimation(exit) { shown = false }
        // Let the card finish animating out, then hand back to the host (which
        // runs the action and clears the request). A plain timer is used rather
        // than `withAnimation(completionCriteria:)`, whose completion handler is
        // unreliable for interpolating springs.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 170 : 340))
            onResolved(action)
        }
    }

    // MARK: Motion

    private var entrance: Animation {
        reduceMotion ? Motion.reducedFallback : Motion.overlay
    }

    private var exit: Animation {
        reduceMotion ? Motion.reducedFallback : Motion.overlay
    }

    private var entranceScale: CGFloat { reduceMotion ? 1 : 0.94 }
    private var entranceBlur: CGFloat { reduceMotion ? 0 : 12 }
}
