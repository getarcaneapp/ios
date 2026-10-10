import SwiftUI
import UIKit

extension View {
    /// Colors the native Back indicator that Liquid Glass renders monochrome
    /// despite SwiftUI tint, and restores this bar's appearance when leaving.
    func appAccentNavigationBar() -> some View {
        modifier(AppAccentNavigationBarModifier())
    }
}

private struct AppAccentNavigationBarModifier: ViewModifier {
    @Environment(\.appAccentColor) private var accent

    func body(content: Content) -> some View {
        content
            .tint(accent)
            .background(NavigationBarAccent(color: UIColor(accent)).allowsHitTesting(false))
    }
}

private struct NavigationBarAccent: UIViewControllerRepresentable {
    let color: UIColor

    func makeUIViewController(context _: Context) -> AccentController {
        let controller = AccentController()
        controller.view.backgroundColor = .clear
        return controller
    }

    func updateUIViewController(_ controller: AccentController, context _: Context) {
        controller.color = color
        controller.applyAccent()
    }

    static func dismantleUIViewController(_ controller: AccentController, coordinator _: ()) {
        controller.deactivate()
    }

    final class AccentController: UIViewController {
        var color: UIColor = .tintColor
        private var isVisible = false
        private weak var bar: UINavigationBar?
        private var originalTint: UIColor?
        private var originalStandard: UINavigationBarAppearance?
        private var originalScrollEdge: UINavigationBarAppearance?
        private var originalCompact: UINavigationBarAppearance?
        private var originalCompactScrollEdge: UINavigationBarAppearance?

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            isVisible = true
            applyAccent()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            applyAccent()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            deactivate()
        }

        func applyAccent() {
            guard isVisible, let navigationBar = navigationController?.navigationBar else { return }
            if bar !== navigationBar {
                restoreAppearance()
                bar = navigationBar
                originalTint = navigationBar.tintColor
                originalStandard = navigationBar.standardAppearance
                originalScrollEdge = navigationBar.scrollEdgeAppearance
                originalCompact = navigationBar.compactAppearance
                originalCompactScrollEdge = navigationBar.compactScrollEdgeAppearance
            }
            guard let standard = originalStandard else { return }
            let indicator = standard.backIndicatorImage
                .withTintColor(color, renderingMode: .alwaysOriginal)
            func accented(_ original: UINavigationBarAppearance) -> UINavigationBarAppearance {
                let appearance = original.copy()
                appearance.setBackIndicatorImage(
                    indicator, transitionMaskImage: standard.backIndicatorTransitionMaskImage)
                appearance.backButtonAppearance.normal.titleTextAttributes[.foregroundColor] = color
                appearance.backButtonAppearance.highlighted.titleTextAttributes[.foregroundColor] = color
                return appearance
            }
            navigationBar.tintColor = color
            navigationBar.standardAppearance = accented(standard)
            navigationBar.scrollEdgeAppearance = accented(originalScrollEdge ?? standard)
            navigationBar.compactAppearance = accented(originalCompact ?? standard)
            navigationBar.compactScrollEdgeAppearance = accented(originalCompactScrollEdge ?? standard)
        }

        func deactivate() {
            isVisible = false
            restoreAppearance()
        }

        private func restoreAppearance() {
            guard let bar, let originalStandard else { return }
            bar.tintColor = originalTint
            bar.standardAppearance = originalStandard
            bar.scrollEdgeAppearance = originalScrollEdge
            bar.compactAppearance = originalCompact
            bar.compactScrollEdgeAppearance = originalCompactScrollEdge
            self.bar = nil
        }
    }
}
