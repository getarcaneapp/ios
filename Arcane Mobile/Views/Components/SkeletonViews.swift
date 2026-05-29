import SwiftUI

// MARK: - Shimmer

extension EnvironmentValues {
    /// Horizontal sweep position (0→1) published by `skeletonShimmer()` and read
    /// by `SkeletonFill`. `nil` means no active shimmer, so placeholders render
    /// static (no ancestor driver, or Reduce Motion is on).
    @Entry var skeletonShimmerPhase: Double? = nil
}

/// Drives a single animation timeline for an entire skeleton subtree and
/// publishes the sweep phase to descendant `SkeletonFill`s, so one clock
/// animates every placeholder in sync. Honors Reduce Motion by leaving the
/// placeholders static.
private struct SkeletonShimmerModifier: ViewModifier {
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Seconds for one full left-to-right sweep.
    private let period: TimeInterval = 1.6

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            TimelineView(.animation) { timeline in
                let elapsed = timeline.date.timeIntervalSinceReferenceDate
                let phase = elapsed.truncatingRemainder(dividingBy: period) / period
                content.environment(\.skeletonShimmerPhase, phase)
            }
        }
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

    @SwiftUI.Environment(\.skeletonShimmerPhase) private var phase
    @SwiftUI.Environment(\.colorScheme) private var colorScheme

    var body: some View {
        shape
            .fill(Color.secondary.opacity(fillOpacity))
            .overlay { highlight }
            .clipShape(shape)
    }

    @ViewBuilder
    private var highlight: some View {
        if let phase {
            GeometryReader { geo in
                let width = geo.size.width
                let band = max(width * 0.45, 28)
                LinearGradient(
                    colors: [.clear, sweepColor, .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: band)
                .offset(x: -band + (width + band) * phase)
            }
            .allowsHitTesting(false)
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

// MARK: - Skeleton list row

/// A row-shaped skeleton mirroring the typical icon + title + trailing-status
/// row used in resource lists (Containers, Images, Networks, Volumes, Projects).
struct SkeletonListRow: View {
    var iconSize: CGFloat = 36
    var titleWidth: CGFloat = 140

    var body: some View {
        HStack(spacing: 12) {
            SkeletonCircle(size: iconSize)
            VStack(alignment: .leading, spacing: 6) {
                SkeletonRect(width: titleWidth, height: 14)
                SkeletonRect(width: titleWidth * 0.55, height: 10)
            }
            Spacer()
            SkeletonRect(width: 44, height: 10)
        }
        .padding(.vertical, 2)
        .accessibilityHidden(true)
    }
}

/// A list of `SkeletonListRow`s wrapped in the same inset-grouped List style
/// the rest of the app uses, with a shimmer applied. Drop this in place of
/// `ProgressView("Loading...")` when first-loading a resource list.
struct SkeletonListLoadingView: View {
    var rowCount: Int = 6
    var titleWidths: [CGFloat] = [160, 110, 180, 140, 100, 150]

    var body: some View {
        List {
            ForEach(0..<rowCount, id: \.self) { idx in
                SkeletonListRow(titleWidth: titleWidths[idx % titleWidths.count])
            }
        }
        .listStyle(.insetGrouped)
        .skeletonShimmer()
        .allowsHitTesting(false)
    }
}
