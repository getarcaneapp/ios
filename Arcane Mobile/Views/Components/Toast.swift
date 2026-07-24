//
//  Toast.swift
//  Arcane Mobile
//
//  A lightweight, app-wide transient toast. The capsule's visual spec and
//  spring/drag behavior are ported from Balaji Venkatesh's LGToast sample; the
//  only changes are (1) the two iOS 26-only glass calls are routed through the
//  app's `GlassCompat` helpers so the project builds for iOS 18, and (2) state
//  is driven by a single `@Observable` presenter + a root `.toastHost()` overlay
//  rather than LGToast's environment values — mirroring `DeleteConfirmation`.
//
//  iOS 26 renders LGToast's Liquid Glass capsule unchanged. On iOS 18 the glass
//  falls back to `.regularMaterial`, so `LegacyFloatChrome` adds a hairline edge
//  and a soft contact shadow (restrained — no colored or additive glow) so the
//  capsule still reads as a floating pill.
//
//  Call sites publish with `showToast(.success("…"))` etc. The host is mounted
//  once in `ContentView` and lifts the toast above the bottom tab bar.
//

import SwiftUI
import UIKit

// MARK: - Haptics

/// Which `HapticsManager` feedback a toast plays when it appears.
enum HapticKind {
    case none, light, success, error

    @MainActor
    func play() {
        switch self {
        case .none:    break
        case .light:   HapticsManager.light()
        case .success: HapticsManager.success()
        case .error:   HapticsManager.error()
        }
    }
}

enum ToastActivityState {
    case running
    case success
    case failure
    case cancelled

    var tint: Color {
        switch self {
        case .running: return .blue
        case .success: return .green
        case .failure: return .red
        case .cancelled: return .secondary
        }
    }
}

// MARK: - Model

struct Toast: Identifiable {
    private(set) var id = UUID().uuidString
    /// The single-line message.
    var title: String
    /// Seconds on screen before auto-dismiss (floored at 1).
    var duration: CGFloat
    /// Extra vertical nudge. Defaults to 0 — the host already lifts the toast
    /// above the tab bar, so callers rarely set this.
    var placementOffset: CGFloat = 0
    /// Slide distance for the enter/exit transition.
    var transitionOffset: CGFloat = 100
    var symbol: String? = nil
    /// Glyph color. Neutral by default; the `success`/`error` factories tint it.
    var symbolTint: Color = .primary
    var actionTitle: String? = nil
    var actionTint: Color = .accentColor
    /// Haptic played once when the toast is presented.
    var haptic: HapticKind = .light
    /// A stable backend activity key enables in-place progress updates.
    var activityID: String? = nil
    /// Normalized activity progress in the 0...1 range.
    var activityProgress: Double? = nil
    var activityState: ToastActivityState? = nil
    /// Active activities remain visible until a terminal stream update arrives.
    var isPersistent = false
    /// Optional whole-toast action used by progress surfaces.
    var tapAction: (@MainActor () -> Void)? = nil
    /// Optional trailing button. Returns `true` to dismiss the toast.
    var action: (@MainActor () -> Bool)? = nil
}

// MARK: - Factories (one-liner call sites)

extension Toast {
    /// Neutral "copied to clipboard" confirmation.
    static func copied(_ title: String = "Copied") -> Toast {
        Toast(title: title, duration: 2, symbol: "doc.on.doc", haptic: .light)
    }

    /// Success confirmation — green check.
    static func success(_ title: String) -> Toast {
        Toast(title: title, duration: 2.5, symbol: "checkmark.circle.fill",
              symbolTint: .green, haptic: .success)
    }

    /// Failure notice — red triangle. Longer so a two-line message can be read.
    static func error(_ title: String) -> Toast {
        Toast(title: title, duration: 5, symbol: "exclamationmark.triangle.fill",
              symbolTint: .red, haptic: .error)
    }

    /// Neutral informational message.
    static func info(_ title: String) -> Toast {
        Toast(title: title, duration: 2.5, symbol: "info.circle", haptic: .light)
    }

    static func activity(id: String, title: String, progress: Double?) -> Toast {
        Toast(
            title: title,
            duration: 2.5,
            symbol: "clock.arrow.circlepath",
            symbolTint: .blue,
            haptic: .light,
            activityID: id,
            activityProgress: progress,
            activityState: .running,
            isPersistent: true,
            tapAction: {
                QuickActionRouter.shared.openActivityCenter()
            }
        )
    }
}

// MARK: - Presenter (single source of truth)

/// App-wide store for the currently-visible toast. Mirrors
/// `DeleteConfirmationPresenter`: one shared instance, a root host renders it,
/// call sites publish via `showToast(_:)`.
@MainActor
@Observable
final class ToastPresenter {
    static let shared = ToastPresenter()
    private init() {}

    private(set) var activeToast: Toast?
    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    func show(_ toast: Toast) {
        dismissTask?.cancel()

        if activeToast != nil {
            // Fade the current toast out first, then present the new one — matches
            // LGToast's ~0.17s hand-off so two toasts don't pile up mid-transition.
            activeToast = nil
            dismissTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(170))
                guard !Task.isCancelled else { return }
                present(toast)
            }
        } else {
            present(toast)
        }
    }

    func showActivity(id: String, title: String, progress: Double?) {
        let normalizedProgress = progress.map { min(max($0, 0), 1) }
        guard var toast = activeToast, toast.activityID == id else {
            show(.activity(id: id, title: title, progress: normalizedProgress))
            return
        }

        dismissTask?.cancel()
        dismissTask = nil
        toast.title = title
        toast.symbol = "clock.arrow.circlepath"
        toast.symbolTint = .blue
        toast.activityProgress = normalizedProgress
        toast.activityState = .running
        toast.isPersistent = true
        activeToast = toast
    }

    func finishActivity(id: String, title: String, state: ToastActivityState, progress: Double?) {
        guard var toast = activeToast, toast.activityID == id else { return }

        dismissTask?.cancel()
        toast.title = terminalTitle(title, state: state)
        toast.symbol = terminalSymbol(state)
        toast.symbolTint = state.tint
        toast.activityProgress = state == .success ? 1 : progress.map { min(max($0, 0), 1) }
        toast.activityState = state
        toast.isPersistent = false
        activeToast = toast

        UIAccessibility.post(notification: .announcement, argument: toast.title)
        scheduleDismiss(after: state == .failure ? 5 : 2.5)
    }

    private func present(_ toast: Toast) {
        activeToast = toast
        toast.haptic.play()
        // VoiceOver doesn't move focus to a transient overlay, so announce it.
        UIAccessibility.post(notification: .announcement, argument: toast.title)

        guard !toast.isPersistent else { return }
        scheduleDismiss(after: max(toast.duration, 1))
    }

    private func scheduleDismiss(after duration: CGFloat) {
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Double(duration)))
            guard !Task.isCancelled else { return }
            dismiss()
        }
    }

    private func terminalTitle(_ title: String, state: ToastActivityState) -> String {
        switch state {
        case .running: return title
        case .success: return "\(title) completed"
        case .failure: return "\(title) failed"
        case .cancelled: return "\(title) cancelled"
        }
    }

    private func terminalSymbol(_ state: ToastActivityState) -> String {
        switch state {
        case .running: return "clock.arrow.circlepath"
        case .success: return "checkmark.circle.fill"
        case .failure: return "exclamationmark.triangle.fill"
        case .cancelled: return "slash.circle.fill"
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        activeToast = nil
    }
}

/// Publish a toast to the app-wide overlay. Main-actor; call from button actions,
/// `@MainActor` view methods, or `Task { @MainActor in … }` completion handlers.
@MainActor func showToast(_ toast: Toast) { ToastPresenter.shared.show(toast) }
@MainActor func showActivityToast(id: String, title: String, progress: Double?) {
    ToastPresenter.shared.showActivity(id: id, title: title, progress: progress)
}
@MainActor func finishActivityToast(
    id: String,
    title: String,
    state: ToastActivityState,
    progress: Double?
) {
    ToastPresenter.shared.finishActivity(id: id, title: title, state: state, progress: progress)
}
@MainActor func dismissToast() { ToastPresenter.shared.dismiss() }

// MARK: - Host (mount once near the root)

extension View {
    /// Mounts the single, app-wide toast overlay. Apply once near the root,
    /// after `.deleteConfirmationHost()` so a toast rides above the delete scrim.
    func toastHost(reservesTabBarSpace: Bool = true) -> some View {
        overlay { ToastHost(reservesTabBarSpace: reservesTabBarSpace) }
    }
}

private struct ToastHost: View {
    @State private var presenter = ToastPresenter.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("arcane.sidebarNavigationEnabled") private var sidebarNavigationEnabled = false
    let reservesTabBarSpace: Bool

    /// Sidebar navigation has no bottom bar, so its toast sits on the bottom safe
    /// area. Root dock navigation adds its own clearance because that host lives
    /// above the `UITabBarController`; sheet-local hosts do not.
    private var barClearance: CGFloat {
        guard reservesTabBarSpace, !sidebarNavigationEnabled else { return 0 }
        if #available(iOS 26, *) { return 60 }
        return 56
    }

    var body: some View {
        GlassContainerCompat(spacing: 10) {
            if let toast = presenter.activeToast {
                ToastCapsule(toast: toast, reduceMotion: reduceMotion) {
                    presenter.dismiss()
                }
                // Fresh identity per toast so its transition runs every time.
                .id(toast.id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, barClearance)
        .allowsHitTesting(presenter.activeToast != nil)
        .animation(
            reduceMotion ? Motion.reducedFallback
                         : Motion.toast,
            value: presenter.activeToast?.id
        )
    }
}

// MARK: - Capsule

private struct ToastCapsule: View {
    let toast: Toast
    let reduceMotion: Bool
    let onDismiss: () -> Void

    var body: some View {
        Group {
            if let tapAction = toast.tapAction {
                Button {
                    tapAction()
                    onDismiss()
                } label: {
                    content
                }
                .buttonStyle(.plain)
            } else {
                content
            }
        }
        .clipShape(.capsule)
        .contentShape(.capsule)
        .glassEffectCompat(in: .capsule)
        .modifier(LegacyFloatChrome())
        .padding(.horizontal, 15)
        .offset(y: toast.placementOffset)
        .gesture(
            DragGesture()
                .onEnded { value in
                    if value.translation.height > 30 { onDismiss() }
                }
        )
        .transition(transition)
        .accessibilityElement(children: .combine)
        .accessibilityValue(activityAccessibilityValue)
    }

    private var content: some View {
        VStack(spacing: toast.activityState == nil ? 0 : 7) {
            HStack(spacing: 10) {
                if let symbol = toast.symbol {
                    Image(systemName: symbol)
                        .font(toast.activityState == nil ? .title3 : .body)
                        .foregroundStyle(toast.symbolTint)
                        .transition(.identity)
                }

                Text(toast.title)
                    .font(toast.activityState == nil ? .body : .subheadline.weight(.medium))
                    // Activity titles stay compact above their progress bar.
                    // Other feedback retains two lines for useful error detail.
                    .lineLimit(toast.activityState == nil ? 2 : 1)

                Spacer(minLength: 0)

                if let progress = toast.activityProgress {
                    Text(verbatim: "\(Int((progress * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if let actionTitle = toast.actionTitle, let action = toast.action {
                    Button {
                        if action() { onDismiss() }
                    } label: {
                        Text(actionTitle)
                            .foregroundStyle(toast.actionTint)
                    }
                    .transition(.identity)
                }
            }

            if let state = toast.activityState {
                ProgressView(value: toast.activityProgress ?? 0)
                    .progressViewStyle(.linear)
                    .tint(state.tint)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: toast.activityState == nil ? 50 : 62)
    }

    private var activityAccessibilityValue: String {
        guard toast.activityState != nil else { return "" }
        guard let progress = toast.activityProgress else { return "In progress" }
        return "\(Int((progress * 100).rounded())) percent"
    }

    private var transition: AnyTransition {
        reduceMotion
            ? .opacity
            : .offset(y: toast.transitionOffset).combined(with: .opacity)
    }
}

/// iOS 18-only depth so the `.regularMaterial` fallback reads as a floating pill.
/// No-op on iOS 26 where Liquid Glass already provides depth. Strictly restrained:
/// a hairline edge + soft contact shadow, no colored or additive glow.
private struct LegacyFloatChrome: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
        } else {
            content
                .overlay {
                    Capsule().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        }
    }
}
