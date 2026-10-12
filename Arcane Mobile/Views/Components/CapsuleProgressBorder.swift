import SwiftUI

extension View {
    /// Progress drawn around a capsule's edge: with a known fraction, a tinted
    /// stroke fills clockwise from the top; while active without a fraction, a
    /// highlight travels around the border instead. Nothing when idle.
    func capsuleProgressBorder(fraction: Double?, isActive: Bool, tint: Color) -> some View {
        modifier(CapsuleProgressBorder(fraction: fraction, isActive: isActive, tint: tint))
    }
}

private struct CapsuleProgressBorder: ViewModifier {
    let fraction: Double?
    let isActive: Bool
    let tint: Color

    func body(content: Content) -> some View {
        content
            .overlay {
                if let fraction {
                    ZStack {
                        Capsule()
                            .strokeBorder(.tertiary, lineWidth: 1)
                        ProgressCapsule(fraction: min(max(fraction, 0), 1))
                            .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .padding(1)
                            .animation(Motion.gauge, value: fraction)
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
            .overlay {
                if isActive && fraction == nil {
                    TravelingCapsuleArc(tint: tint)
                        .allowsHitTesting(false)
                }
            }
    }
}

/// Indeterminate progress: a short accent arc with a fading tail travels
/// around the capsule. Reduce Motion shows the arc at rest at the top.
private struct TravelingCapsuleArc: View {
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let lapDuration: TimeInterval = 1.8
    private static let arcLength = 0.22

    var body: some View {
        ZStack {
            Capsule()
                .strokeBorder(.tertiary, lineWidth: 1)
            TimelineView(.animation(paused: reduceMotion)) { context in
                let phase =
                    reduceMotion
                    ? 0
                    : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.lapDuration)
                        / Self.lapDuration
                ZStack {
                    // Tail: longer and fainter, ending where the head begins.
                    ProgressCapsule(fraction: 1, window: (phase - Self.arcLength * 2, phase))
                        .stroke(tint.opacity(0.3), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    ProgressCapsule(fraction: 1, window: (phase - Self.arcLength, phase))
                        .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                }
                .padding(1)
            }
        }
    }
}

/// A capsule outline that starts at the top center and runs clockwise, so a
/// trimmed stroke reads as progress filling in around the edge. `window`
/// selects a slice of the outline instead, wrapping past the start.
private nonisolated struct ProgressCapsule: Shape {
    var fraction: Double
    var window: (start: Double, end: Double)? = nil

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let outline = Self.outline(in: rect)
        guard let window else { return outline.trimmedPath(from: 0, to: fraction) }
        let start = window.start - floor(window.start)
        let end = start + (window.end - window.start)
        if end <= 1 { return outline.trimmedPath(from: start, to: end) }
        var path = outline.trimmedPath(from: start, to: 1)
        path.addPath(outline.trimmedPath(from: 0, to: end - 1))
        return path
    }

    private static func outline(in rect: CGRect) -> Path {
        let radius = min(rect.height, rect.width) / 2
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addArc(
            center: CGPoint(x: rect.maxX - radius, y: rect.minY + radius), radius: radius,
            startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addArc(
            center: CGPoint(x: rect.minX + radius, y: rect.maxY - radius), radius: radius,
            startAngle: .degrees(90), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()
        return path
    }
}
