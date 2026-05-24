import SwiftUI

// MARK: - Shimmer

/// A subtle animated highlight that sweeps across the receiver. Used to make
/// `.redacted(reason: .placeholder)` content feel alive while data loads.
/// Disabled when the user has Reduce Motion turned on; falls back to a static
/// dim of the underlying content so loading is still visually distinct.
struct ShimmerModifier: ViewModifier {
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isActive: Bool

    func body(content: Content) -> some View {
        if !isActive {
            content
        } else if reduceMotion {
            content.opacity(0.7)
        } else {
            content
                .overlay {
                    TimelineView(.animation) { timeline in
                        let elapsed = timeline.date.timeIntervalSinceReferenceDate
                        let phase = (elapsed.truncatingRemainder(dividingBy: 1.6)) / 1.6
                        GeometryReader { geo in
                            LinearGradient(
                                colors: [.clear, Color.white.opacity(0.35), .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: geo.size.width * 0.55)
                            .offset(x: -geo.size.width * 0.55 + geo.size.width * 1.55 * phase)
                        }
                        .blendMode(.plusLighter)
                        .allowsHitTesting(false)
                    }
                    .mask(content)
                }
        }
    }
}

extension View {
    /// Apply a shimmer overlay. Pair with `.redacted(reason: .placeholder)` on
    /// the same view tree to indicate loading.
    func shimmering(active: Bool = true) -> some View {
        modifier(ShimmerModifier(isActive: active))
    }
}

// MARK: - Skeleton primitives

/// A neutral gray rounded rectangle used as a stand-in for text or other
/// content while data loads. Sized to look like the content it replaces.
struct SkeletonRect: View {
    var width: CGFloat?
    var height: CGFloat
    var cornerRadius: CGFloat = 4

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.secondary.opacity(0.18))
            .frame(width: width, height: height)
    }
}

/// A neutral gray circle, sized for avatar/icon-style placeholders.
struct SkeletonCircle: View {
    var size: CGFloat

    var body: some View {
        Circle()
            .fill(Color.secondary.opacity(0.18))
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
        .redacted(reason: .placeholder)
        .shimmering()
        .allowsHitTesting(false)
    }
}
