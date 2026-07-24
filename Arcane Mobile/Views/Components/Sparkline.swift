import SwiftUI

/// One point in a sparkline series.
nonisolated struct SparklineSample: Equatable, Sendable {
    let timestamp: Date
    let value: Double
}

/// Health/Stocks-style rolling sparkline: a thin solid line over a soft
/// gradient fill. Restrained — no glow (house rule). The Y scale is fixed so
/// the line never rescale-jumps as new samples arrive, and X uses real
/// timestamps so reconnect gaps render honestly.
///
/// The frame height is constant whether data is present or not — cards using
/// Liquid Glass cache their shape, so data arrival must never change geometry.
struct Sparkline: View {
    let samples: [SparklineSample]
    let tint: Color
    /// Fixed value domain; defaults to 0–100 for percentage series.
    var range: ClosedRange<Double> = 0...100
    var height: CGFloat = 36

    var body: some View {
        Canvas(opaque: false, colorMode: .linear, rendersAsynchronously: true) { context, size in
            if samples.count < 2 {
                var placeholder = Path()
                let y = size.height / 2
                placeholder.move(to: CGPoint(x: 0, y: y))
                placeholder.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(
                    placeholder,
                    with: .color(.secondary.opacity(0.2)),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                )
            } else {
                drawSparkline(in: &context, size: size)
            }
        }
        .frame(height: height)
        // Live dashboard streams can deliver several series updates each
        // second. Drawing the latest path directly avoids overlapping whole-
        // chart animations while the user scrolls through environment cards.
        .accessibilityHidden(true)
    }

    private func drawSparkline(in context: inout GraphicsContext, size: CGSize) {
        guard let first = samples.first, let last = samples.last,
              size.width > 0, size.height > 0 else { return }

        let startTime = first.timestamp.timeIntervalSinceReferenceDate
        let timeSpan = max(last.timestamp.timeIntervalSinceReferenceDate - startTime, 1)
        let valueSpan = max(range.upperBound - range.lowerBound, .leastNonzeroMagnitude)

        var points: [CGPoint] = []
        points.reserveCapacity(samples.count)
        for sample in samples {
            let elapsed = sample.timestamp.timeIntervalSinceReferenceDate - startTime
            let x = size.width * CGFloat(elapsed / timeSpan)
            let normalized = min(max((sample.value - range.lowerBound) / valueSpan, 0), 1)
            let y = size.height * (1 - CGFloat(normalized))
            points.append(CGPoint(x: x, y: y))
        }

        guard let firstPoint = points.first, let lastPoint = points.last else { return }

        var line = Path()
        line.move(to: firstPoint)
        for point in points.dropFirst() {
            line.addLine(to: point)
        }

        var area = line
        area.addLine(to: CGPoint(x: lastPoint.x, y: size.height))
        area.addLine(to: CGPoint(x: firstPoint.x, y: size.height))
        area.closeSubpath()

        context.fill(
            area,
            with: .linearGradient(
                Gradient(colors: [tint.opacity(0.18), tint.opacity(0.02)]),
                startPoint: .zero,
                endPoint: CGPoint(x: 0, y: size.height)
            )
        )
        context.stroke(
            line,
            with: .color(tint),
            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
        )
    }
}
