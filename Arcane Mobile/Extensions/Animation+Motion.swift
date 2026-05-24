import SwiftUI

extension View {
    /// Apply an implicit animation that gracefully disables itself when the
    /// system's Reduce Motion accessibility setting is enabled.
    ///
    /// Use this in place of `.animation(_:value:)` for any motion that exists
    /// purely for polish (transitions, list reflow, content swaps). Required
    /// motion — e.g. a progress indicator — should stay on `.animation` so
    /// users still see what's happening.
    func motionAwareAnimation<V: Equatable>(
        _ animation: Animation?,
        value: V
    ) -> some View {
        modifier(MotionAwareAnimationModifier(animation: animation, value: value))
    }
}

private struct MotionAwareAnimationModifier<V: Equatable>: ViewModifier {
    let animation: Animation?
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension AnyTransition {
    /// A transition that combines opacity with movement when Reduce Motion is
    /// off, collapsing to a pure cross-fade when it's on.
    static func motionAware(edge: Edge, reduceMotion: Bool) -> AnyTransition {
        reduceMotion
            ? .opacity
            : .opacity.combined(with: .move(edge: edge))
    }
}
