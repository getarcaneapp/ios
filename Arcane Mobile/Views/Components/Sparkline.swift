import SwiftUI
import Charts

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
        Group {
            if samples.count < 2 {
                placeholder
            } else {
                chart
            }
        }
        .frame(height: height)
        .motionAwareAnimation(Motion.state, value: samples)
        .accessibilityHidden(true)
    }

    private var chart: some View {
        Chart(samples, id: \.timestamp) { sample in
            AreaMark(
                x: .value("Time", sample.timestamp),
                y: .value("Value", sample.value)
            )
            .interpolationMethod(.monotone)
            .foregroundStyle(
                LinearGradient(
                    colors: [tint.opacity(0.18), tint.opacity(0.02)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            LineMark(
                x: .value("Time", sample.timestamp),
                y: .value("Value", sample.value)
            )
            .interpolationMethod(.monotone)
            .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .foregroundStyle(tint)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartYScale(domain: range)
    }

    /// Flat hairline shown until two samples exist, at the same fixed height.
    private var placeholder: some View {
        Capsule()
            .fill(.secondary.opacity(0.2))
            .frame(height: 1.5)
            .frame(maxHeight: .infinity, alignment: .center)
    }
}
