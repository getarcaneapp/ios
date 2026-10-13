import SwiftUI

/// The Arcane logo tracing itself on: each piece's outline draws in, then its
/// fill seeps in while the outline fades, with later pieces starting a little
/// after earlier ones. When `loops`, the finished logo holds, fades, and
/// starts over.
struct ArcaneLogoTrace: View {
    let logo: LaunchLogoPaths
    let accent: Color
    /// Seconds since the trace began; negative while waiting to start.
    let time: TimeInterval
    var loops = false

    private static let pieceDuration: TimeInterval = 1.1
    private static let stagger: TimeInterval = 0.045
    private static let holdDuration: TimeInterval = 0.6
    private static let fadeDuration: TimeInterval = 0.45
    private static let restDuration: TimeInterval = 0.25

    static func duration(pieceCount: Int) -> TimeInterval {
        pieceDuration + stagger * TimeInterval(max(pieceCount - 1, 0))
    }

    static func cycleDuration(pieceCount: Int) -> TimeInterval {
        duration(pieceCount: pieceCount) + holdDuration + fadeDuration + restDuration
    }

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            let traceDuration = Self.duration(pieceCount: logo.pieces.count)
            var time = time
            if loops, time > 0 {
                time = time.truncatingRemainder(dividingBy: Self.cycleDuration(pieceCount: logo.pieces.count))
                let fadeStart = traceDuration + Self.holdDuration
                if time >= fadeStart + Self.fadeDuration { return }
                if time > fadeStart {
                    context.opacity = 1 - (time - fadeStart) / Self.fadeDuration
                }
            }

            let scale = min(size.width / logo.size.width, size.height / logo.size.height)
            let origin = CGPoint(
                x: (size.width - logo.size.width * scale) / 2,
                y: (size.height - logo.size.height * scale) / 2
            )
            context.translateBy(x: origin.x, y: origin.y)
            context.scaleBy(x: scale, y: scale)

            for piece in logo.pieces {
                let local = (time - Self.stagger * TimeInterval(piece.order)) / Self.pieceDuration
                guard local > 0 else { continue }
                let progress = Self.ease(min(local, 1))
                let path = Path(piece.path)

                let fill = Self.fillOpacity(at: progress)
                if fill > 0 {
                    context.fill(path, with: .color(accent.opacity(fill)))
                }
                let stroke = Self.strokeOpacity(at: progress)
                if stroke > 0 {
                    let traced = path.trimmedPath(from: 0, to: min(progress / 0.5, 1))
                    context.stroke(
                        traced,
                        with: .color(accent.opacity(stroke)),
                        // Keep the outline the same thickness at any size.
                        style: StrokeStyle(lineWidth: 2 / scale * 0.83, lineCap: .round, lineJoin: .round)
                    )
                }
            }
        }
    }

    /// Outline finishes at the halfway point; the fill seeps in over the
    /// second half while the outline fades out.
    private static func fillOpacity(at progress: Double) -> Double {
        switch progress {
        case ..<0.5: 0
        case ..<0.62: (progress - 0.5) / 0.12 * 0.35
        case ..<0.88: 0.35 + (progress - 0.62) / 0.26 * 0.65
        default: 1
        }
    }

    private static func strokeOpacity(at progress: Double) -> Double {
        switch progress {
        case ..<0.62: 1
        case ..<0.88: 1 - (progress - 0.62) / 0.26 * 0.4
        default: 0.6 - (progress - 0.88) / 0.12 * 0.6
        }
    }

    /// Fast start, long settle.
    private static func ease(_ x: Double) -> Double {
        1 - pow(1 - x, 2.6)
    }
}

/// Loading placeholder: the Arcane logo drawing itself on a loop, with an
/// optional caption. Use in place of a spinner wherever a screen or section
/// is loading. Falls back to a system spinner without the logo asset or
/// with Reduce Motion on.
struct ArcaneLoadingView: View {
    enum Style {
        /// Centered logo with the caption underneath, for a loading screen or section.
        case regular
        /// Small logo beside the caption, for a row or footer.
        case inline
    }

    let label: String?
    var style: Style = .regular

    @Environment(\.appAccentColor) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let logo = LaunchLogoPaths.bundled

    init(_ label: String? = nil, style: Style = .regular) {
        self.label = label
        self.style = style
    }

    private var logoSize: CGFloat { style == .regular ? 56 : 22 }

    var body: some View {
        Group {
            if let logo = Self.logo, !reduceMotion {
                switch style {
                case .regular:
                    VStack(spacing: 12) {
                        drawing(logo)
                        caption
                    }
                case .inline:
                    HStack(spacing: 10) {
                        drawing(logo)
                        caption
                    }
                }
            } else if let label {
                ProgressView(label)
            } else {
                ProgressView()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label ?? "Loading")
        .accessibilityAddTraits(.updatesFrequently)
    }

    private func drawing(_ logo: LaunchLogoPaths) -> some View {
        // 60 fps is plenty for a loading trace; ProMotion would otherwise
        // redraw every loader at 120 Hz.
        TimelineView(.animation(minimumInterval: 1.0 / 60)) { context in
            ArcaneLogoTrace(
                logo: logo, accent: accent, time: context.date.timeIntervalSinceReferenceDate, loops: true
            )
            .background {
                // A faint silhouette the trace draws over.
                Image(decorative: "ArcaneLogo")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(accent.opacity(0.12))
            }
        }
        .frame(width: logoSize, height: logoSize * logo.size.height / logo.size.width)
    }

    @ViewBuilder
    private var caption: some View {
        if let label {
            Text(label)
                .font(style == .regular ? .subheadline : .body)
                .foregroundStyle(.secondary)
        }
    }
}
