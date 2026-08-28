import SwiftUI
import WebKit

extension EnvironmentValues {
    @Entry var isLaunchSplashPresented = false
}

struct ArcaneLaunchSplash: View {
    let accentColorHex: String
    @Binding var isPresented: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var logoLoadState: AnimatedLogoLoadState = .loading
    @State private var isExiting = false

    private var phase: Phase {
        if reduceMotion || !ArcaneAnimatedLogoWebView.isAvailable || logoLoadState == .failed {
            return .staticLogo
        }
        return logoLoadState == .ready ? .animating : .loading
    }

    private var resolvedAccentColorHex: String {
        LaunchLogoColor.normalizedHex(accentColorHex)
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)

            Group {
                if phase == .staticLogo {
                    Image(decorative: "ArcaneLogo")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(Color(hex: resolvedAccentColorHex) ?? .blue)
                } else {
                    ArcaneAnimatedLogoWebView(
                        accentColorHex: resolvedAccentColorHex,
                        loadState: $logoLoadState
                    )
                }
            }
            .frame(width: 180, height: 173)
            .scaleEffect(isExiting && !reduceMotion ? 7.5 : 1)
        }
        .opacity(isExiting ? 0 : 1)
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .task(id: phase) {
            switch phase {
            case .staticLogo:
                await finish(after: .milliseconds(reduceMotion ? 250 : 500))
            case .loading:
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
                guard logoLoadState == .loading else { return }
                logoLoadState = .failed
            case .animating:
                await finish(after: .milliseconds(2450))
            }
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

        let exitDuration = reduceMotion
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
    static let defaultHex = "#007AFF"

    static func normalizedHex(_ rawValue: String) -> String {
        let cleaned = rawValue
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

        let coloredLogo = logo
            .replacingOccurrences(of: "fill:#6d28d9", with: "fill:\(accentColorHex)")
            .replacingOccurrences(of: "stroke:#6d28d9", with: "stroke:\(accentColorHex)")
        let html = template.replacingOccurrences(of: "{{ARCANE_LOGO}}", with: coloredLogo)
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
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

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loadState.wrappedValue = .ready
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            loadState.wrappedValue = .failed
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            loadState.wrappedValue = .failed
        }
    }
}
