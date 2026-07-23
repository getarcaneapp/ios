//
//  DeploymentPill.swift
//  Arcane Mobile
//
//  Floating in-app indicator for the active deployment operation, modeled on
//  the Toast capsule. The Dynamic Island never shows a foreground app's own
//  Live Activity, so this pill is the in-app progress surface: it appears
//  whenever an operation exists and the full-log sheet is hidden, and tapping
//  it reopens the sheet.
//
//  Liquid Glass rules: the capsule has a fixed height and enters/exits via
//  scale + opacity — the glass shape's frame is never animated, and tint swaps
//  happen discretely on state changes, never off interpolated progress.
//

import SwiftUI

extension View {
    /// Mounts the deployment pill overlay and the root stream sheet. Apply once
    /// near the root, before `.toastHost()` so toasts layer above the pill.
    /// Root-only: mounting a second host inside a sheet double-binds the
    /// stream-sheet presentation and SwiftUI tears one down.
    func deploymentActivityHost() -> some View {
        modifier(DeploymentActivityHostModifier())
    }
}

private struct DeploymentActivityHostModifier: ViewModifier {
    @State private var store = DeploymentActivityStore.shared

    func body(content: Content) -> some View {
        @Bindable var store = store
        content
            .overlay { DeploymentPillHost() }
            .sheet(isPresented: $store.isSheetPresented) {
                if let operation = store.operation {
                    InstallStreamSheet(
                        operation: operation,
                        onCancel: { store.cancel() },
                        onDone: { store.acknowledge() }
                    )
                }
            }
    }
}

// MARK: - Host

private struct DeploymentPillHost: View {
    @State private var store = DeploymentActivityStore.shared
    @State private var toastPresenter = ToastPresenter.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("arcane.sidebarNavigationEnabled") private var sidebarNavigationEnabled = false

    /// Same navigation-aware clearance as ToastHost — the pill sits where a toast
    /// would, including at the bottom safe area when the sidebar replaces the bar.
    private var barClearance: CGFloat {
        guard !sidebarNavigationEnabled else { return 0 }
        if #available(iOS 26, *) { return 60 }
        return 56
    }

    /// When a toast is visible the pill steps up one slot so they stack
    /// (toast above the tab bar, pill above the toast).
    private var toastClearance: CGFloat {
        toastPresenter.activeToast != nil ? 58 : 0
    }

    private var isPillVisible: Bool {
        store.operation != nil && !store.isSheetPresented
    }

    var body: some View {
        GlassContainerCompat(spacing: 10) {
            if let operation = store.operation, !store.isSheetPresented {
                DeploymentPillView(
                    operation: operation,
                    onTap: { store.isSheetPresented = true },
                    onDismiss: { store.acknowledge() }
                )
                .id(operation.id)
                .transition(pillTransition)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, barClearance + toastClearance)
        .allowsHitTesting(isPillVisible)
        .animation(pillAnimation, value: isPillVisible)
        .animation(pillAnimation, value: toastPresenter.activeToast?.id)
    }

    private var pillAnimation: Animation {
        reduceMotion ? Motion.reducedFallback : Motion.overlay
    }

    private var pillTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .scale(scale: 0.9).combined(with: .opacity)
    }
}

// MARK: - Pill

private struct DeploymentPillView: View {
    let operation: DeploymentOperation
    let onTap: () -> Void
    let onDismiss: () -> Void

    private var status: InstallStreamStatus { operation.status }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                statusIcon

                VStack(alignment: .leading, spacing: 1) {
                    Text(operation.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(caption)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }

                Spacer(minLength: 8)

                trailingIndicator
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .clipShape(.capsule)
        .glassEffectCompat(in: .capsule)
        .modifier(PillLegacyFloatChrome())
        .padding(.horizontal, 15)
        .gesture(
            DragGesture()
                .onEnded { value in
                    // Only a finished pill can be flicked away — a running
                    // operation's indicator shouldn't vanish by accident.
                    if status.isTerminal, value.translation.height > 30 {
                        onDismiss()
                    }
                }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the full log")
    }

    private var statusIcon: some View {
        Group {
            switch status {
            case .running:
                Image(systemName: operation.kind.systemImage)
                    .symbolEffect(.pulse, options: .repeating)
                    .foregroundStyle(.blue)
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failure:
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(.red)
            }
        }
        .font(.body.weight(.semibold))
    }

    private var caption: String {
        switch status {
        case .running:
            let phase = operation.currentPhase ?? "Working"
            if let fraction = operation.progressFraction {
                return "\(phase) · \(Int(fraction * 100))%"
            }
            return "\(phase)…"
        case .success:
            return "Complete"
        case .failure:
            return "Failed — tap for details"
        }
    }

    @ViewBuilder
    private var trailingIndicator: some View {
        switch status {
        case .running:
            if let fraction = operation.progressFraction {
                ProgressRing(fraction: fraction)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        case .success, .failure:
            EmptyView()
        }
    }

    private var accessibilityText: String {
        var parts = [operation.title, caption]
        if case .running = status, operation.progressFraction == nil {
            parts.append("in progress")
        }
        return parts.joined(separator: ", ")
    }
}

/// Small determinate ring for pull progress. Trim animation is plain vector
/// drawing (not glass), so animating it is safe.
private struct ProgressRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(.tertiary, lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(Motion.gauge, value: fraction)
        }
        .frame(width: 18, height: 18)
    }
}

/// iOS 18-only depth so the `.regularMaterial` fallback reads as a floating
/// pill — mirrors Toast's LegacyFloatChrome (hairline + soft shadow, no glow).
private struct PillLegacyFloatChrome: ViewModifier {
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
