import SwiftUI

/// A Liquid Glass "morph" container: a small `label` reshapes into a larger
/// `content` panel as `progress` runs 0 → 1, the glass shape interpolating from
/// the label's footprint to the content's. Anchored by `alignment` (use
/// `.bottom` to grow a bottom-pinned label *upward*).
///
/// Adapted from FXTabBar's `ExpandableGlassEffect` (Balaji Venkatesh, 2026) — the
/// same blur/scale/opacity morph driven by an `Animatable` `progress`. Two
/// changes for this app:
///   * `@available(iOS 26, *)` — it uses `GlassEffectContainer` / `.glassEffect`
///     directly, which is fine because the type is only ever referenced from
///     iOS-26 branches (the rule documented in `GlassCompat.swift`). On iOS 18
///     the long-press swap keeps the `TabSwapSheet` modal instead.
///   * Hit-testing is gated by `progress` so the (faded-out) label on top doesn't
///     swallow taps meant for the expanded content, and the live label stays
///     interactive at rest.
@available(iOS 26, *)
struct ExpandableGlassEffect<Content: View, Label: View>: View, Animatable {
    var alignment: Alignment
    var progress: CGFloat
    /// Discrete on/off for the morph's own Liquid Glass **and** the label frame
    /// pin. Driven by the host as a plain (non-interpolated) flag — set true when
    /// an expand begins, false only once a collapse has fully settled. Toggling
    /// the glass off the per-frame `progress` instead leaves the glass slab
    /// lingering behind the bar after dismiss (the structural `.glassEffect`
    /// add/remove doesn't diff cleanly against the running interpolation).
    var morphing: Bool = false
    var labelSize: CGSize = .init(width: 55, height: 55)
    var cornerRadius: CGFloat = 30
    @ViewBuilder var content: Content
    @ViewBuilder var label: Label
    /// View Properties
    @State private var contentSize: CGSize = .zero

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        GlassEffectContainer {
            let widthDiff = contentSize.width - labelSize.width
            let heightDiff = contentSize.height - labelSize.height

            let rWidth = widthDiff * contentOpacity
            let rHeight = heightDiff * contentOpacity

            ZStack(alignment: alignment) {
                content
                    .compositingGroup()
                    .scaleEffect(contentScale)
                    .blur(radius: 14 * blurProgress)
                    .opacity(contentOpacity)
                    .onGeometryChange(for: CGSize.self) {
                        $0.size
                    } action: { newValue in
                        if newValue.isMeaningfullyDifferent(from: contentSize) {
                            contentSize = newValue
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(
                        width: labelSize.width + rWidth,
                        height: labelSize.height + rHeight
                    )
                    // Only catch touches once expanded — at rest the live label
                    // underneath must remain interactive.
                    .allowsHitTesting(progress > 0.5)
                    .accessibilityHidden(progress <= 0.5)

                label
                    .compositingGroup()
                    .blur(radius: 14 * blurProgress)
                    .opacity(1 - labelOpacity)
                    // Only pin to `labelSize` while morphing — at rest the label
                    // keeps its natural size so a host whose label changes shape
                    // (e.g. a tab bar that itself morphs into detail controls)
                    // isn't distorted by a fixed frame.
                    .frame(
                        width: morphing ? labelSize.width : nil,
                        height: morphing ? labelSize.height : nil
                    )
                    // Stop the faded-out label from blocking taps to the content.
                    .allowsHitTesting(progress < 0.5)
                    .accessibilityHidden(progress > 0.5)
            }
            .compositingGroup()
            .clipShape(.rect(cornerRadius: cornerRadius))
            // Glass only while morphing. At rest this is a passthrough so the
            // host's label keeps its own glass/shape — the morph capsule would
            // otherwise sit on top of it (tabs) or draw a slab behind separate
            // pills (detail controls). Gated on the discrete `morphing` flag, not
            // `progress`, so the slab is removed cleanly on dismiss instead of
            // lingering.
            .modifier(MorphGlass(active: morphing, cornerRadius: cornerRadius))
        }
        .scaleEffect(
            x: 1 - (blurProgress * 0.5),
            y: 1 + (blurProgress * 0.35),
            anchor: scaleAnchor
        )
        .offset(y: offset * blurProgress)
    }

    var labelOpacity: CGFloat {
        min(progress / 0.35, 1)
    }

    var contentOpacity: CGFloat {
        max(progress - 0.35, 0) / 0.65
    }

    var contentScale: CGFloat {
        // Before the content has been measured, `contentSize` is zero — avoid the
        // divide-by-zero (which yields NaN and blanks the first frame).
        guard contentSize.width > 0, contentSize.height > 0 else { return 1 }
        let minAspectScale = min(labelSize.width / contentSize.width, labelSize.height / contentSize.height)

        return minAspectScale + (1 - minAspectScale) * progress
    }

    var blurProgress: CGFloat {
        /// 0 -> 0.5 -> 0. Clamped because a spring `progress` can overshoot
        /// outside [0, 1] (the expand's bounce), which would otherwise drive a
        /// negative blur radius and an inverted scale — a visible glitch.
        let raw = progress > 0.5 ? (1 - progress) / 0.5 : progress / 0.5
        return max(0, min(1, raw))
    }

    var offset: CGFloat {
        switch alignment {
        case .bottom, .bottomLeading, .bottomTrailing: return -80
        case .top, .topLeading, .topTrailing: return 80
        /// Center!
        default: return -10
        }
    }

    /// Converting Alignment into UnitPoint for ScaleEffect
    var scaleAnchor: UnitPoint {
        switch alignment {
        case .bottomLeading: .bottomLeading
        case .bottom: .bottom
        case .bottomTrailing: .bottomTrailing
        case .topLeading: .topLeading
        case .top: .top
        case .topTrailing: .topTrailing
        case .leading: .leading
        case .trailing: .trailing
        default: .center
        }
    }
}

/// Applies the morph's Liquid Glass only while expanding. Pulled out so the
/// `.glassEffect` can be conditional without breaking the view-builder chain.
///
/// Non-`.interactive()` on purpose: this is a passive panel background (the
/// tiles inside handle their own touches). An interactive glass tracks touch
/// state, and since dismiss usually follows a tap, removing it mid-tracking can
/// leave a residual highlight lingering behind the bar.
@available(iOS 26, *)
private struct MorphGlass: ViewModifier {
    let active: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        if active {
            content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            content
        }
    }
}

@available(iOS 26, *)
private extension CGSize {
    func isMeaningfullyDifferent(from other: CGSize) -> Bool {
        abs(width - other.width) > 0.5 || abs(height - other.height) > 0.5
    }
}
