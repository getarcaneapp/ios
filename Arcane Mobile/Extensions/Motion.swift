import SwiftUI

enum TabIndicatorMotion: String, CaseIterable, Identifiable {
    case straight
    case parabolic
    case teleport

    static let storageKey = "arcane.tabIndicatorMotion"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .straight: "Straight"
        case .parabolic: "Parabolic"
        case .teleport: "Teleport"
        }
    }
}

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
    /// Default content / state / tint swap.
    static let state: Animation = .smooth(duration: 0.25)

    /// Brief fade for visuals that must clear before a longer surface morph finishes.
    static let earlyFade: Animation = .easeOut(duration: 0.1)

    /// List section reflow (filter, sort, pin, insert/remove).
    static let reflow: Animation = .smooth(duration: 0.3)

    /// Card / first-appear entrance.
    static let entrance: Animation = .spring(response: 0.42, dampingFraction: 0.85)

    /// Delete-confirmation card entrance/exit.
    static let overlay: Animation = .interpolatingSpring(duration: 0.3)

    /// Long-press tab-replace: the Liquid Glass picker callout growing out of —
    /// and shrinking back into — the tab being replaced. A touch of bounce sells
    /// the "pop" (iOS 26 only).
    static let morph: Animation = .bouncy(duration: 0.5, extraBounce: 0.05)

    /// Toast host entrance/exit.
    static let toast: Animation = .interpolatingSpring(duration: 0.35, bounce: 0)

    /// Progress bars and the dashboard stat ring.
    static let gauge: Animation = .spring(response: 0.55, dampingFraction: 0.85)

    /// Continuous state changes in the environment-wide update scene.
    static let updateStage: Animation = .spring(response: 0.68, dampingFraction: 0.88)

    /// Slow simulated parallax drift for the active fleet-update bubble.
    static let updateBubbleDrift: Animation = .easeInOut(duration: 1.8)

    /// Heavily damped handoff between completed and newly active update bubbles.
    static let updateBubbleHandoff: Animation = .spring(response: 0.68, dampingFraction: 0.94)

    /// Login logo one-shot "pop" on first appear. Softer, springier entrance
    /// than `entrance` — a lower damping fraction gives it a little more bounce
    /// for the single hero moment on the sign-in screen.
    static let logoEntrance: Animation = .spring(response: 0.55, dampingFraction: 0.62)

    /// Splash handoff from the centered logo into the app content.
    static let splashExitDuration: TimeInterval = 0.65
    static let splashExit: Animation = .easeInOut(duration: splashExitDuration)

    /// Autoscroll tracking that must stay glued to live-appended output
    /// (terminal). Deliberately linear and short — a smooth/spring token would
    /// lag behind streaming text and read as rubber-banding.
    static let follow: Animation = .linear(duration: 0.1)

    /// A quick fade used as the Reduce-Motion fallback where *some* motion is
    /// still wanted (transient overlays — toast, delete card) instead of an
    /// instant cut.
    static let reducedFallbackDuration: TimeInterval = 0.2
    static let reducedFallback: Animation = .easeOut(duration: reducedFallbackDuration)

    /// Returns `animation` normally, or `nil` when Reduce Motion is on — so
    /// `withAnimation(Motion.reduced(.reflow, reduceMotion: reduceMotion)) { … }`
    /// collapses to an instant change for users who opt out of motion.
    static func reduced(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }

    /// Reduce-Motion adapter for third-party APIs that require a non-optional
    /// `Animation` and therefore cannot accept the `nil` returned above.
    static func reducedRequired(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? .linear(duration: 0) : animation
    }
}

// MARK: - Card entrance

/// A one-shot scale + fade entrance for cards and tiles. Plays once per
/// identity and never again — the latch outlives the view, so LazyVStack
/// teardown (e.g. the Dashboard grid covered by a pushed page) doesn't replay
/// the entrance when the user swipes back. Restrained: 2% scale, no slide, no
/// glow. Reduce Motion drops the scale (fade only).
private struct CardEntranceModifier: ViewModifier {
    let identity: String
    @State private var hasAppeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Process-lifetime latch. Survives view teardown; intentionally resets on
    /// relaunch so the entrance still plays once per session.
    private static var seenIdentities = Set<String>()

    func body(content: Content) -> some View {
        let hasPlayed = hasAppeared || Self.seenIdentities.contains(identity)
        content
            .scaleEffect(reduceMotion || hasPlayed ? 1 : 0.98)
            .opacity(hasPlayed ? 1 : 0)
            .onAppear {
                guard !hasAppeared, !Self.seenIdentities.contains(identity) else { return }
                Self.seenIdentities.insert(identity)
                withAnimation(reduceMotion ? Motion.reducedFallback : Motion.entrance) {
                    hasAppeared = true
                }
            }
    }
}

extension View {
    /// One-shot scale + fade entrance for a card / tile. Pass a stable
    /// `identity` — the latch is keyed on it and survives scroll-lazy teardown,
    /// so returning to the page never replays the animation.
    func cardEntrance(id: String) -> some View {
        modifier(CardEntranceModifier(identity: id))
    }
}

// MARK: - Loading cross-fade

/// Cross-fades between a loading skeleton and loaded content. Set
/// `animatesTransition` to false when either branch is a `List`; an inherited
/// animation transaction can otherwise animate internal row geometry.
///
/// Replaces the abrupt `Group { if isLoading { Skeleton } else { … } }` swap.
/// Pass the full non-loading branch (error / empty / list) as `content`.
struct LoadingCrossfade<Skeleton: View, Content: View>: View {
    let showSkeleton: Bool
    let animatesTransition: Bool
    @ViewBuilder var skeleton: Skeleton
    @ViewBuilder var content: Content

    init(
        showSkeleton: Bool,
        animatesTransition: Bool = true,
        @ViewBuilder skeleton: () -> Skeleton,
        @ViewBuilder content: () -> Content
    ) {
        self.showSkeleton = showSkeleton
        self.animatesTransition = animatesTransition
        self.skeleton = skeleton()
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if animatesTransition {
            ZStack {
                if showSkeleton {
                    skeleton.transition(.opacity)
                } else {
                    content.transition(.opacity)
                }
            }
            .motionAwareAnimation(Motion.state, value: showSkeleton)
        } else if showSkeleton {
            skeleton
        } else {
            content
        }
    }
}
