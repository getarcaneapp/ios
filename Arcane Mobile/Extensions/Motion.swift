import SwiftUI

// MARK: - Motion tokens
//
// A single, restrained motion vocabulary for the app. Animation timings used to
// be hand-typed and scattered across ~15 files; these named tokens are the one
// source of truth. Each value lands on a timing already in use, so adopting a
// token is a like-for-like swap with no perceptible change.
//
// House style — keep every new animation here honest: restrained, contained,
// transforms + opacity only, no additive glow. Every animated surface must stay
// Reduce-Motion correct: drive polish through `motionAwareAnimation(_:value:)`
// (see Animation+Motion.swift) or `Motion.reduced(_:reduceMotion:)`.

enum Motion {
    /// Button press in/out. Snappy, no bounce.
    static let press: Animation = .spring(response: 0.28, dampingFraction: 0.82)

    /// Default content / state / tint swap.
    static let state: Animation = .smooth(duration: 0.25)

    /// List section reflow (filter, sort, pin, insert/remove).
    static let reflow: Animation = .smooth(duration: 0.3)

    /// Card / first-appear entrance.
    static let entrance: Animation = .spring(response: 0.42, dampingFraction: 0.85)

    /// Root overlay (delete-confirmation card) entrance/exit.
    static let overlay: Animation = .interpolatingSpring(duration: 0.3)

    /// Long-press tab-replace: the bottom bar's Liquid Glass **expand** into the
    /// tab picker. A touch of bounce sells the "morph" (iOS 26 only). Bounce is
    /// safe on expand — it overshoots the *open* state, never the resting state.
    static let morph: Animation = .bouncy(duration: 0.5, extraBounce: 0.05)

    /// The **collapse** half of the same morph. Deliberately non-bouncy: a bounce
    /// here undershoots past the bar's resting state, which is exactly where the
    /// morph's Liquid Glass switches off — so the spring would flick the glass
    /// off/on as it settles (a flash on dismiss). A smooth spring lands straight
    /// on rest.
    static let morphCollapse: Animation = .smooth(duration: 0.4)

    /// Toast host entrance/exit.
    static let toast: Animation = .interpolatingSpring(duration: 0.35, bounce: 0)

    /// Progress bars and the dashboard stat ring.
    static let gauge: Animation = .spring(response: 0.55, dampingFraction: 0.85)

    /// A quick fade used as the Reduce-Motion fallback where *some* motion is
    /// still wanted (transient overlays — toast, delete card) instead of an
    /// instant cut.
    static let reducedFallback: Animation = .easeOut(duration: 0.2)

    /// Returns `animation` normally, or `nil` when Reduce Motion is on — so
    /// `withAnimation(Motion.reduced(.reflow, reduceMotion: reduceMotion)) { … }`
    /// collapses to an instant change for users who opt out of motion.
    static func reduced(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}

// MARK: - Pressable button style

/// Restrained press feedback for standalone buttons, cards, tiles, and chips:
/// a subtle scale + opacity dip on press, contained to the control (no shadow,
/// tint, or glow change). Motion-aware — under Reduce Motion the scale is
/// dropped and only the opacity dip remains.
///
/// Do NOT apply to `NavigationLink` rows that carry `.matchedTransitionSource`:
/// a scaling style snapshots a transformed frame and makes the hero zoom
/// stutter, and it competes with the list cell's swipe / context-menu gestures.
/// List rows keep their native highlight.
struct PressableButtonStyle: ButtonStyle {
    /// Plays a light haptic on press-down. Off by default — reserve haptics for
    /// meaningful actions, not high-frequency chips.
    var hapticOnPress: Bool = false
    /// Whether the press dips the scale. Set `false` for a view that is also a
    /// `.matchedTransitionSource` hero-zoom source: a geometry change there can
    /// disturb the zoom snapshot, so it gets an opacity-only press instead.
    var scaleOnPress: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var pressedScale: CGFloat {
        (reduceMotion || !scaleOnPress) ? 1 : 0.97
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(Motion.press, value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed && hapticOnPress { HapticsManager.light() }
            }
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    /// Restrained press feedback (scale + opacity). See `PressableButtonStyle`.
    static var pressable: PressableButtonStyle { PressableButtonStyle() }

    /// Pressable with options: `haptic` plays a light tap on press-down (for
    /// meaningful actions); `scales: false` gives an opacity-only press for
    /// hero-zoom source views.
    static func pressable(haptic: Bool = false, scales: Bool = true) -> PressableButtonStyle {
        PressableButtonStyle(hapticOnPress: haptic, scaleOnPress: scales)
    }
}

// MARK: - Card entrance

/// A one-shot scale + fade entrance for cards and tiles. Plays once when the
/// view first appears and never again — the latch persists for the view's
/// lifetime, so data refreshes (pull-to-refresh) don't replay it. Restrained:
/// 2% scale, no slide, no glow. Reduce Motion drops the scale (fade only).
private struct CardEntranceModifier: ViewModifier {
    @State private var hasAppeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(reduceMotion ? 1 : (hasAppeared ? 1 : 0.98))
            .opacity(hasAppeared ? 1 : 0)
            .onAppear {
                guard !hasAppeared else { return }
                withAnimation(reduceMotion ? Motion.reducedFallback : Motion.entrance) {
                    hasAppeared = true
                }
            }
    }
}

extension View {
    /// One-shot scale + fade entrance for a card / tile. Plays once; never
    /// replays on data refresh. See `CardEntranceModifier`.
    func cardEntrance() -> some View {
        modifier(CardEntranceModifier())
    }
}

// MARK: - Loading cross-fade

/// Cross-fades between a loading skeleton and loaded content. Both branches are
/// typically `List`s, so this is a reliable container-level opacity cross-fade
/// rather than a flaky per-row `List` transition. Collapses to an instant swap
/// under Reduce Motion.
///
/// Replaces the abrupt `Group { if isLoading { Skeleton } else { … } }` swap.
/// Pass the full non-loading branch (error / empty / list) as `content`.
struct LoadingCrossfade<Skeleton: View, Content: View>: View {
    let showSkeleton: Bool
    @ViewBuilder var skeleton: Skeleton
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            if showSkeleton {
                skeleton.transition(.opacity)
            } else {
                content.transition(.opacity)
            }
        }
        .motionAwareAnimation(Motion.state, value: showSkeleton)
    }
}
