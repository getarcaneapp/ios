import SwiftUI

extension EnvironmentValues {
    @Entry var isLaunchSplashPresented = false
}

/// The launch splash: the logo settles in as a faint silhouette, traces
/// itself on piece by piece and fills, then lifts away as the app appears.
/// Drawn natively so it runs at the display's full frame rate.
struct ArcaneLaunchSplash: View {
    let accentColorHex: String
    @Binding var isPresented: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var hasAppeared = false
    /// Starts at the first drawn frame, so launch stalls before the splash
    /// renders don't eat into the drawing.
    @State private var clock = LaunchClock()
    @State private var sheenOffset: CGFloat = -1
    /// Set once the drawing is done so the hand-off animates a plain image
    /// instead of the live drawing.
    @State private var showsFinishedLogo = false
    @State private var isBreathing = false

    private static let logoSize = CGSize(width: 150, height: 144)
    private static let logo = LaunchLogoPaths.bundled

    /// The trace starts as the silhouette settles and ends when the last
    /// piece has filled.
    private static let traceStart: TimeInterval = 0.2
    private static let traceEnd = traceStart + ArcaneLogoTrace.duration(pieceCount: logo?.pieces.count ?? 13)

    private var accent: Color {
        Color(hex: LaunchLogoColor.normalizedHex(accentColorHex)) ?? .accentColor
    }

    private var tracesNatively: Bool {
        !reduceMotion && Self.logo != nil
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)

            glow
                .opacity(hasAppeared ? 1 : 0)
                .scaleEffect(reduceMotion || hasAppeared ? 1 : 0.6)

            ZStack {
                if tracesNatively && !showsFinishedLogo, let logo = Self.logo {
                    // A faint silhouette the trace draws over, so the logo
                    // has a presence before the drawing starts.
                    staticLogo
                        .opacity(0.12)
                        .modifier(settleIn)
                    // Only the trace redraws per frame; the rest of the
                    // splash animates through ordinary SwiftUI animations.
                    TimelineView(.animation) { context in
                        ArcaneLogoTrace(
                            logo: logo, accent: accent, time: clock.elapsed(at: context.date) - Self.traceStart)
                    }
                } else {
                    staticLogo
                        .modifier(settleIn)
                }
            }
            .frame(width: Self.logoSize.width, height: Self.logoSize.height)
            .overlay { sheen }
            .opacity(hasAppeared ? 1 : 0)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .onAppear {
            withAnimation(reduceMotion ? Motion.reducedFallback : Motion.splashEnter) {
                hasAppeared = true
            }
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: Self.breathHalfPeriod).repeatForever(autoreverses: true)) {
                isBreathing = true
            }
        }
        .task {
            guard tracesNatively else {
                sweepSheen(after: .milliseconds(reduceMotion ? 0 : 450))
                await finish(after: .milliseconds(reduceMotion ? 600 : 1500))
                return
            }
            // Same timeline as the drawing: the sheen crosses the logo as the
            // last pieces fill, then the logo lifts away over the app.
            do {
                try await Task.sleep(for: .seconds(Self.traceEnd - 0.35))
            } catch {
                return
            }
            sweepSheen(after: .zero)
            await finish(after: .milliseconds(900))
        }
    }

    /// Half of the glow's breathing cycle (it used to follow `sin(t * 1.1)`).
    private static let breathHalfPeriod: TimeInterval = .pi / 1.1

    private var staticLogo: some View {
        Image(decorative: "ArcaneLogo")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .foregroundStyle(accent)
    }

    private var settleIn: LaunchSettleModifier {
        LaunchSettleModifier(settled: reduceMotion || hasAppeared)
    }

    /// A soft pool of the accent behind the logo that slowly breathes. Kept
    /// faint so it tints the screen rather than glowing.
    private var glow: some View {
        let strength = colorScheme == .dark ? 0.3 : 0.18
        let breath = reduceMotion ? 1 : (isBreathing ? 1.035 : 0.965)
        return RadialGradient(
            colors: [accent.opacity(strength), accent.opacity(strength * 0.4), .clear],
            center: .center,
            startRadius: 0,
            endRadius: 300
        )
        .scaleEffect(breath)
    }

    /// One soft highlight that crosses the filled logo.
    private var sheen: some View {
        GeometryReader { proxy in
            LinearGradient(
                colors: [.clear, .white.opacity(colorScheme == .dark ? 0.16 : 0.24), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: proxy.size.width * 0.45)
            .rotationEffect(.degrees(18))
            .offset(x: sheenOffset * proxy.size.width)
        }
        .mask {
            Image(decorative: "ArcaneLogo")
                .resizable()
                .scaledToFit()
        }
        .allowsHitTesting(false)
    }

    private func sweepSheen(after delay: Duration) {
        guard !reduceMotion else { return }
        withAnimation(Motion.splashSheen.delay(delay.seconds)) {
            sheenOffset = 1.4
        }
    }

    /// Hands off to the app: the removal transition lifts and dissolves the
    /// finished logo over the app content.
    private func finish(after delay: Duration) async {
        do {
            try await Task.sleep(for: delay)
            // Swap the drawing for the identical static logo a frame before
            // the lift, so the exit scale and blur animate a plain image.
            showsFinishedLogo = true
            try await Task.sleep(for: .milliseconds(32))
        } catch {
            return
        }
        withAnimation(reduceMotion ? Motion.reducedFallback : Motion.splashExit) {
            isPresented = false
        }
    }
}

/// Wall clock for the splash, started by the first drawn frame.
private final class LaunchClock {
    private var start: Date?

    func elapsed(at date: Date) -> TimeInterval {
        guard let start else {
            self.start = date
            return 0
        }
        return date.timeIntervalSince(start)
    }
}

/// The logo's settle-in: from slightly small and soft to crisp and in place.
struct LaunchSettleModifier: ViewModifier {
    let settled: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(settled ? 1 : 0.86)
            .blur(radius: settled ? 0 : 12)
    }
}

/// The splash's removal: lifts toward the viewer and dissolves.
struct LaunchSplashExitModifier: ViewModifier {
    let progress: CGFloat
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(reduceMotion ? 1 : 1 + 0.14 * progress)
            .blur(radius: reduceMotion ? 0 : 14 * progress)
            .opacity(1 - progress)
    }
}

extension AnyTransition {
    static func launchSplashExit(reduceMotion: Bool) -> AnyTransition {
        .asymmetric(
            insertion: .identity,
            removal: .modifier(
                active: LaunchSplashExitModifier(progress: 1, reduceMotion: reduceMotion),
                identity: LaunchSplashExitModifier(progress: 0, reduceMotion: reduceMotion)
            )
        )
    }
}

extension Duration {
    fileprivate var seconds: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}

private enum LaunchLogoColor {
    static let defaultHex = "#AF52DE"

    static func normalizedHex(_ rawValue: String) -> String {
        let cleaned =
            rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 6, UInt64(cleaned, radix: 16) != nil else {
            return defaultHex
        }
        return "#\(cleaned.uppercased())"
    }
}
