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

    /// Same navigation-aware clearance as ToastHost — the pill sits where a toast
    /// would, above the bottom dock.
    private var barClearance: CGFloat {
        if #available(iOS 26, *) { return 60 }
        return 56
    }

    /// When a toast is visible the pill steps up one slot so they stack
    /// (toast above the tab bar, pill above the toast).
    private var toastClearance: CGFloat {
        toastPresenter.activeToast.map { $0.height + 8 } ?? 0
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Completion sweep: the border fills all the way around, then the
    /// checkmark takes over.
    @State private var completionFill: Double?
    @State private var showsCheckmark = false

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
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        // Progress runs around the pill's edge instead of a spinner inside it.
        // Drawn inside the glass: content layered above the glass effect isn't shown.
        .capsuleProgressBorder(
            fraction: status == .running ? operation.progressFraction : completionFill,
            isActive: status == .running,
            tint: status == .success ? .green : .accentColor
        )
        .clipShape(.capsule)
        .glassEffectCompat(in: .capsule)
        .task(id: status) {
            guard case .success = status else { return }
            await sweepToCheckmark()
        }
        .modifier(PillLegacyFloatChrome())
        .motionAwareAnimation(Motion.state, value: status)
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
                if showsCheckmark {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                } else {
                    Image(systemName: operation.kind.systemImage)
                        .foregroundStyle(.blue)
                }
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

    /// Success: the border sweeps around the whole pill in green, then fades
    /// as the checkmark pops in. Reduce Motion goes straight to the checkmark.
    private func sweepToCheckmark() async {
        guard !reduceMotion else {
            showsCheckmark = true
            return
        }
        completionFill = 0
        do {
            try await Task.sleep(for: .milliseconds(32))
            withAnimation(Motion.completionSweep) { completionFill = 1 }
            try await Task.sleep(for: .milliseconds(650))
            withAnimation(Motion.entrance) { showsCheckmark = true }
            try await Task.sleep(for: .milliseconds(350))
            withAnimation(Motion.state) { completionFill = nil }
        } catch {
            showsCheckmark = true
            completionFill = nil
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
                .floatingSurfaceShadow()
        }
    }
}
