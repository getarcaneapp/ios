import SwiftUI

// MARK: - Shimmer

extension EnvironmentValues {
    /// Set by `skeletonShimmer()` for descendant `SkeletonFill`s. False means
    /// no active shimmer, so placeholders render static (no ancestor driver,
    /// or Reduce Motion is on).
    @Entry var skeletonShimmerActive = false
}

/// Turns on the sweep for every `SkeletonFill` in a skeleton subtree. Each fill
/// runs one repeating animation that SwiftUI interpolates on its own, instead
/// of a per-frame timeline re-evaluating the whole skeleton. Fills appear
/// together, so their sweeps stay in step. Honors Reduce Motion.
private struct SkeletonShimmerModifier: ViewModifier {
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.environment(\.skeletonShimmerActive, !reduceMotion)
    }
}

extension View {
    /// Animate a synchronized, self-contained shimmer across every `SkeletonFill`
    /// in this subtree. Apply once to the skeleton container (e.g. the loading
    /// `List`). Placeholders render static without it or under Reduce Motion.
    func skeletonShimmer() -> some View {
        modifier(SkeletonShimmerModifier())
    }
}

// MARK: - Skeleton primitives

/// A neutral placeholder fill for `shape`, with a subtle highlight that sweeps
/// across while data loads. The highlight is clipped to `shape`, so it stays
/// contained to the element and never bleeds onto neighboring content. Reads
/// its sweep position from `skeletonShimmer()`; renders static without one.
struct SkeletonFill<S: Shape>: View {
    var shape: S
    var fillOpacity: Double = 0.18

    @SwiftUI.Environment(\.skeletonShimmerActive) private var shimmerActive
    @SwiftUI.Environment(\.colorScheme) private var colorScheme
    @State private var swept = false

    /// Seconds for one full left-to-right sweep.
    private static var period: TimeInterval { 1.6 }

    var body: some View {
        shape
            .fill(Color.secondary.opacity(fillOpacity))
            .overlay { highlight }
            .clipShape(shape)
    }

    @ViewBuilder
    private var highlight: some View {
        if shimmerActive {
            GeometryReader { geo in
                let width = geo.size.width
                let band = max(width * 0.45, 28)
                LinearGradient(
                    colors: [.clear, sweepColor, .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: band)
                .offset(x: swept ? width : -band)
            }
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.linear(duration: Self.period).repeatForever(autoreverses: false)) {
                    swept = true
                }
            }
        }
    }

    /// A gentle lift over the base fill — a faint glow in dark mode, a soft wash
    /// in light mode. Composited normally (not additive), so it reads as
    /// "loading" without glare.
    private var sweepColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.10)
            : Color.white.opacity(0.40)
    }
}

/// A neutral gray rounded rectangle used as a stand-in for text or other
/// content while data loads. Sized to look like the content it replaces.
struct SkeletonRect: View {
    var width: CGFloat?
    var height: CGFloat
    var cornerRadius: CGFloat = 4

    var body: some View {
        SkeletonFill(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .frame(width: width, height: height)
    }
}

/// A neutral gray circle, sized for avatar/icon-style placeholders.
struct SkeletonCircle: View {
    var size: CGFloat

    var body: some View {
        SkeletonFill(shape: Circle())
            .frame(width: size, height: size)
    }
}
