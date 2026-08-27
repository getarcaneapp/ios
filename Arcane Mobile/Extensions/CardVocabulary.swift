import SwiftUI

// Shared card/chip surface vocabulary extracted from DashboardView.swift so
// every domain can adopt the dashboard's look without importing its file.

extension View {
    /// Canonical card surface: `secondarySystemGroupedBackground` fill at a
    /// continuous radius. Liquid Glass path on iOS 26+; iOS 18 adds the soft
    /// depth pillow (shadow riding the fill + 1pt top-edge highlight).
    func dashboardCardBackground(cornerRadius: CGFloat = Radius.card) -> some View {
        self.modifier(DashboardCardBackgroundModifier(cornerRadius: cornerRadius))
    }

    /// Raised chip fill inside a card: a lighter grouped tone lifts it off the
    /// card in dark mode, and a tight drop shadow on the fill does the lifting
    /// in light mode. Restrained — no glow.
    func raisedChipBackground<S: Shape>(in shape: S) -> some View {
        background(
            shape.fill(
                Color(uiColor: .tertiarySystemGroupedBackground)
                    .shadow(.drop(color: .black.opacity(0.15), radius: 3, y: 1))
            )
        )
    }

    /// Shadow tier for transient surfaces that float above content — toasts,
    /// pills, floating action rows, custom dialogs. The only sanctioned deep
    /// shadow; cards and chips get their lift from `ShapeStyle.shadow` inside
    /// their background fills instead.
    func floatingSurfaceShadow() -> some View {
        shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    }
}

/// Row-link style for NavigationLinks/Buttons that present card rows. Custom
/// styles bypass the system highlight, which stays latched after popping back
/// from a pushed page when the row carries a custom background/contentShape.
/// Press feedback is a restrained dim + 1% shrink, owned entirely by SwiftUI's
/// gesture (reliably released on pop).
struct CardRowLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.65 : 1)
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(Motion.state, value: configuration.isPressed)
    }
}

extension View {
    func cardRowLinkStyle() -> some View {
        buttonStyle(CardRowLinkStyle())
    }
}

struct DashboardCardBackgroundModifier: ViewModifier {
    let cornerRadius: CGFloat
    // Arcane ships its own `Environment` model, which shadows SwiftUI's property
    // wrapper — reach for the fully-qualified one.
    @SwiftUI.Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            // Liquid Glass already supplies depth; this path is a plain fill and
            // only inherits the larger radius.
            content
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemGroupedBackground))
                )
        } else {
            // iOS 18 fallback — the "soft depth" pillow cue. The drop shadow
            // rides on the fill (via `ShapeStyle.shadow`) so it hugs the shape
            // rather than the whole subtree, and a 1pt top-edge highlight fakes
            // "light from above" convexity. Restrained — no glow.
            content
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            Color(uiColor: .secondarySystemGroupedBackground)
                                .shadow(.drop(color: .black.opacity(0.06), radius: 8, y: 3))
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    .white.opacity(colorScheme == .dark ? 0.07 : 0.35),
                                    .clear
                                ],
                                startPoint: .top,
                                endPoint: .center
                            ),
                            lineWidth: 1
                        )
                        .allowsHitTesting(false)
                )
        }
    }
}
