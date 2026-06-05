import SwiftUI

// MARK: - Liquid Glass back-deployment helpers
//
// The app's Liquid Glass UI (iOS 26+) renders byte-for-byte identically to
// before — these helpers only add iOS 18 fallbacks so the project can build and
// run with `IPHONEOS_DEPLOYMENT_TARGET = 18.0`. The iOS 18 fallbacks follow the
// house pattern already used in `RowPreviewCard` and `DashboardCardBackgroundModifier`:
// frosted material for panels, opaque tinted fills for icon chips (so a white /
// hierarchical glyph stays legible), plain controls where glass was decorative.
//
// The iOS 26-only `Glass` type is only ever referenced inside an
// `if #available(iOS 26, *)` branch, so nothing here is visible to the iOS 18
// code path.

/// Builds the `Glass` value for a call site. Kept out of the `@ViewBuilder`
/// methods below because its imperative body (the `if let` / `if` mutations)
/// can't live inside a view builder.
@available(iOS 26, *)
private func arcaneGlass(tint: Color?, interactive: Bool) -> Glass {
    var glass: Glass = .regular
    if let tint { glass = glass.tint(tint) }
    if interactive { glass = glass.interactive() }
    return glass
}

extension View {
    /// Liquid Glass on iOS 26+, frosted-material (or tint-wash) fallback on iOS 18.
    /// Use for panels, cards, and capsules — surfaces whose content uses semantic
    /// (`.primary` / `.secondary`) or colored foreground styles that read fine over material.
    @ViewBuilder
    func glassEffectCompat<S: Shape>(tint: Color? = nil, interactive: Bool = false, in shape: S) -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(arcaneGlass(tint: tint, interactive: interactive), in: shape)
        } else if let tint {
            self.background(tint.opacity(0.15), in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
        }
    }

    /// Icon chip: Liquid Glass on iOS 26+, an **opaque** tinted fill on iOS 18 so a
    /// white / hierarchical glyph layered on top stays legible. Mirrors `RowPreviewCard`.
    @ViewBuilder
    func glassChipCompat<S: Shape>(tint: Color, interactive: Bool = false, in shape: S) -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(arcaneGlass(tint: tint, interactive: interactive), in: shape)
        } else {
            self.background(tint, in: shape)
        }
    }

    /// `.buttonStyle(.glassProminent)` on iOS 26+, `.borderedProminent` on iOS 18.
    /// Mirrors `RunEndpointButton`.
    @ViewBuilder
    func glassProminentButtonStyleCompat() -> some View {
        if #available(iOS 26, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }

    /// `.buttonStyle(.glass)` on iOS 26+, `.bordered` on iOS 18.
    @ViewBuilder
    func glassButtonStyleCompat() -> some View {
        if #available(iOS 26, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }

    /// `.scrollEdgeEffectStyle(.soft, for: .top)` on iOS 26+, no-op on iOS 18.
    @ViewBuilder
    func softTopScrollEdgeEffectCompat() -> some View {
        if #available(iOS 26, *) {
            self.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }

    /// Bare `.glassEffect()` (default capsule) on iOS 26+, no-op on iOS 18. For
    /// items that live inside a `GlassContainerCompat` and need no standalone
    /// fallback (e.g. toolbar buttons whose bar already provides the chrome).
    @ViewBuilder
    func glassEffectCompat() -> some View {
        if #available(iOS 26, *) {
            self.glassEffect()
        } else {
            self
        }
    }

    /// Additive glass on iOS 26+, **nothing** on iOS 18. For views that already
    /// supply their own opaque background (so no fallback fill is wanted) and
    /// only layer Liquid Glass on top when it's available.
    @ViewBuilder
    func glassEffectOverlayCompat<S: Shape>(tint: Color? = nil, interactive: Bool = false, in shape: S) -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(arcaneGlass(tint: tint, interactive: interactive), in: shape)
        } else {
            self
        }
    }
}

/// `GlassEffectContainer` on iOS 26+, a transparent passthrough on iOS 18.
/// Lets a cluster of `.glassEffectCompat()` children blend on iOS 26 while
/// rendering as plain views on iOS 18.
struct GlassContainerCompat<Content: View>: View {
    var spacing: CGFloat? = nil
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}
