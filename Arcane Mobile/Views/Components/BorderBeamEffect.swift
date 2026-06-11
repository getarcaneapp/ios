import SwiftUI

/// Animated "border beam": a short gradient arc that travels around a rounded
/// rectangle's edge, with a soft masked glow trailing along the border.
/// Ported from Balaji Venkatesh's BorderBeam demo, adapted to render as an
/// overlay (so it sits above material fills) and to respect Reduce Motion.
extension View {
    @ViewBuilder
    func borderBeam(
        border: Color,
        hideFadeBorder: Bool = true,
        beam: [Color],
        beamBlur: CGFloat,
        cornerRadius: CGFloat,
        isEnabled: Bool = true
    ) -> some View {
        self
            .modifier(
                BorderBeamEffect(
                    border: border,
                    hideFadeBorder: hideFadeBorder,
                    beam: beam,
                    beamBlur: beamBlur,
                    cornerRadius: cornerRadius,
                    isEnabled: isEnabled
                )
            )
    }
}

struct BorderBeamEffect: ViewModifier {
    var border: Color
    var hideFadeBorder: Bool
    var beam: [Color]
    var beamBlur: CGFloat
    var cornerRadius: CGFloat
    var isEnabled: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay {
                if isEnabled {
                    BorderBeamView()
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
    }

    private var shape: RoundedRectangle {
        .rect(cornerRadius: cornerRadius, style: .continuous)
    }

    @ViewBuilder
    private func BorderBeamView() -> some View {
        ZStack {
            /// OPTIONAL: Faded Border
            if !hideFadeBorder {
                shape
                    .stroke(border.tertiary, lineWidth: 0.6)
            }

            if reduceMotion {
                // Static gradient stroke: same identity, no travelling motion.
                shape
                    .strokeBorder(
                        LinearGradient(
                            colors: beam,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.5
                    )
            } else {
                /// Using Keyframe Animator to animate the border beam!
                KeyframeAnimator(initialValue: 0.0, repeating: true) { value in
                    let rotation = value * 360

                    let borderGradient = AngularGradient(
                        colors: [.clear, border, .clear],
                        center: .center,
                        startAngle: .degrees(140 + rotation),
                        endAngle: .degrees(270 + rotation)
                    )

                    let beamGradient = LinearGradient(
                        colors: beam,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )

                    /// Beam Gradient
                    shape
                        .fill(beamGradient)
                        /// Inverse masking to show only some limited amount of beam gradient
                        .mask {
                            Rectangle()
                                .overlay {
                                    shape
                                        /// Using blur instead of padding, so that we can get smooth ending
                                        .blur(radius: beamBlur)
                                        .blendMode(.destinationOut)
                                }
                        }
                        .mask {
                            /// Masking it with the already having border gradient to sync with the border effect
                            shape
                                .fill(borderGradient)
                                .blur(radius: beamBlur / 1.5)
                                .padding(-beamBlur * 2)
                        }

                    /// Border Gradient
                    shape
                        .stroke(borderGradient, lineWidth: 0.6)
                } keyframes: { _ in
                    LinearKeyframe(1, duration: 2.5)
                }
            }
        }
        .padding(0.5)
    }
}
