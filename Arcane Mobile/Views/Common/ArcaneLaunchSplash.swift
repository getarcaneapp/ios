import SwiftUI
import WebKit

extension EnvironmentValues {
    @Entry var isLaunchSplashPresented = false
}

struct ArcaneLaunchSplash: View {
    let accentColorHex: String
    @Binding var isPresented: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var logoLoadState: AnimatedLogoLoadState = .loading
    @State private var hasAppeared = false
    @State private var sheenOffset: CGFloat = -1
    @State private var isExiting = false

    private static let logoSize = CGSize(width: 150, height: 144)

    private var phase: Phase {
        if reduceMotion || !ArcaneAnimatedLogoWebView.isAvailable || logoLoadState == .failed {
            return .staticLogo
        }
        return logoLoadState == .ready ? .animating : .loading
    }

    private var resolvedAccentColorHex: String {
        LaunchLogoColor.normalizedHex(accentColorHex)
    }

    private var accent: Color {
        Color(hex: resolvedAccentColorHex) ?? .accentColor
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)

            backdrop
                .opacity(hasAppeared && !isExiting ? 1 : 0)
                .scaleEffect(reduceMotion ? 1 : backdropScale)

            logo
                .frame(width: Self.logoSize.width, height: Self.logoSize.height)
                .overlay { sheen }
                .scaleEffect(reduceMotion ? 1 : logoScale)
                .blur(radius: reduceMotion ? 0 : logoBlur)
                .opacity(hasAppeared ? 1 : 0)
        }
        .opacity(isExiting ? 0 : 1)
        .onAppear {
            withAnimation(reduceMotion ? Motion.reducedFallback : Motion.splashEnter) {
                hasAppeared = true
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .task(id: phase) {
            switch phase {
            case .staticLogo:
                sweepSheen()
                await finish(after: .milliseconds(reduceMotion ? 500 : 1100))
            case .loading:
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
                guard logoLoadState == .loading else { return }
                logoLoadState = .failed
            case .animating:
                // The trace draw fills the logo at about 1.1s; a single sheen
                // follows, then the splash hands off.
                do {
                    try await Task.sleep(for: .milliseconds(1100))
                } catch {
                    return
                }
                sweepSheen()
                await finish(after: .milliseconds(1100))
            }
        }
    }

    @ViewBuilder
    private var logo: some View {
        if phase == .staticLogo {
            Image(decorative: "ArcaneLogo")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(accent)
        } else {
            ArcaneAnimatedLogoWebView(
                accentColorHex: resolvedAccentColorHex,
                loadState: $logoLoadState
            )
        }
    }

    /// A slowly drifting wash of the accent behind the logo. Kept faint so it
    /// tints the screen rather than glowing.
    private var backdrop: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let strength = colorScheme == .dark ? 0.32 : 0.2
            MeshGradient(
                width: 3,
                height: 3,
                points: Self.meshPoints(at: time),
                colors: [
                    .clear, accent.opacity(strength * 0.5), .clear,
                    accent.opacity(strength * 0.7), accent.opacity(strength), accent.opacity(strength * 0.45),
                    .clear, accent.opacity(strength * 0.6), .clear,
                ]
            )
        }
    }

    private static func meshPoints(at time: TimeInterval) -> [SIMD2<Float>] {
        let drift = { (speed: Double, phase: Double) in Float(sin(time * speed + phase) * 0.06) }
        return [
            [0, 0], [0.5 + drift(0.7, 0), 0], [1, 0],
            [0, 0.5 + drift(0.6, 1)], [0.5 + drift(0.9, 2), 0.5 + drift(0.8, 3)], [1, 0.5 + drift(0.5, 4)],
            [0, 1], [0.5 + drift(0.65, 5), 1], [1, 1],
        ]
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

    private var backdropScale: CGFloat {
        if isExiting { return 1.2 }
        return hasAppeared ? 1 : 0.7
    }

    /// Settles in from slightly small, then lifts slightly on exit.
    private var logoScale: CGFloat {
        if isExiting { return 1.08 }
        return hasAppeared ? 1 : 0.94
    }

    private var logoBlur: CGFloat {
        if isExiting { return 10 }
        return hasAppeared ? 0 : 6
    }

    private func sweepSheen() {
        guard !reduceMotion else { return }
        withAnimation(Motion.splashSheen) {
            sheenOffset = 1.4
        }
    }

    private func finish(after delay: Duration) async {
        do {
            try await Task.sleep(for: delay)
        } catch {
            return
        }

        withAnimation(reduceMotion ? Motion.reducedFallback : Motion.splashExit) {
            isExiting = true
        }

        let exitDuration =
            reduceMotion
            ? Motion.reducedFallbackDuration
            : Motion.splashExitDuration
        do {
            try await Task.sleep(for: .seconds(exitDuration))
        } catch {
            return
        }
        isPresented = false
    }

    private enum Phase: Hashable {
        case staticLogo
        case loading
        case animating
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

private enum AnimatedLogoLoadState: Hashable {
    case loading
    case ready
    case failed
}

private struct ArcaneAnimatedLogoWebView: UIViewRepresentable {
    let accentColorHex: String
    @Binding var loadState: AnimatedLogoLoadState

    private static let templateURL =
        Bundle.main.url(
            forResource: "ArcaneLaunchLogo",
            withExtension: "html",
            subdirectory: "Resources"
        ) ?? Bundle.main.url(forResource: "ArcaneLaunchLogo", withExtension: "html")

    private static let logoURL =
        Bundle.main.url(
            forResource: "logo-animated",
            withExtension: "svg",
            subdirectory: "Resources"
        ) ?? Bundle.main.url(forResource: "logo-animated", withExtension: "svg")

    static var isAvailable: Bool { templateURL != nil && logoURL != nil }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.underPageBackgroundColor = .clear
        webView.isUserInteractionEnabled = false
        webView.isAccessibilityElement = false
        webView.accessibilityElementsHidden = true
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.bounces = false
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never

        guard
            let templateURL = Self.templateURL,
            let logoURL = Self.logoURL,
            let template = try? String(contentsOf: templateURL, encoding: .utf8),
            let logo = try? String(contentsOf: logoURL, encoding: .utf8),
            template.contains("{{ARCANE_LOGO}}")
        else {
            context.coordinator.loadState.wrappedValue = .failed
            return webView
        }

        let coloredLogo =
            logo
            .replacingOccurrences(of: "fill:#6d28d9", with: "fill:\(accentColorHex)")
            .replacingOccurrences(of: "stroke:#6d28d9", with: "stroke:\(accentColorHex)")
        let html = template.replacingOccurrences(of: "{{ARCANE_LOGO}}", with: coloredLogo)
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }

    func updateUIView(_: WKWebView, context: Context) {
        context.coordinator.loadState = $loadState
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(loadState: $loadState)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadState: Binding<AnimatedLogoLoadState>

        init(loadState: Binding<AnimatedLogoLoadState>) {
            self.loadState = loadState
        }

        func webView(_: WKWebView, didFinish _: WKNavigation!) {
            loadState.wrappedValue = .ready
        }

        func webView(
            _: WKWebView,
            didFail _: WKNavigation!,
            withError _: Error
        ) {
            loadState.wrappedValue = .failed
        }

        func webView(
            _: WKWebView,
            didFailProvisionalNavigation _: WKNavigation!,
            withError _: Error
        ) {
            loadState.wrappedValue = .failed
        }
    }
}
