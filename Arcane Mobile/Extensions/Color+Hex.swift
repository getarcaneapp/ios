import SwiftUI

extension Color {
    init?(hex: String) {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 6, let number = UInt64(cleaned, radix: 16) else { return nil }
        self.init(
            red: Double((number >> 16) & 0xFF) / 255,
            green: Double((number >> 8) & 0xFF) / 255,
            blue: Double(number & 0xFF) / 255
        )
    }

    var hexString: String? {
        guard let components = UIColor(self).cgColor.components, components.count >= 3 else { return nil }
        let r = Int(components[0] * 255)
        let g = Int(components[1] * 255)
        let b = Int(components[2] * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

private struct AppAccentColorKey: EnvironmentKey {
    static let defaultValue: Color = .blue
}

extension EnvironmentValues {
    var appAccentColor: Color {
        get { self[AppAccentColorKey.self] }
        set { self[AppAccentColorKey.self] = newValue }
    }
}

extension View {
    /// Applies the saved app accent to modern tint styles and to existing
    /// `Color.accentColor` surfaces. SwiftUI's `.tint` alone does not update
    /// the latter, which otherwise continue to render in system blue.
    func appAccentColor(_ color: Color?) -> some View {
        accentColor(color)
            .tint(color)
            .environment(\.appAccentColor, color ?? .blue)
    }

    /// Applies Arcane's saved accent directly to a toolbar symbol. iOS 26
    /// renders ordinary Liquid Glass toolbar controls as monochrome, so their
    /// inherited tint is not enough to color the icon.
    func appAccentToolbarSymbol() -> some View {
        modifier(AppAccentToolbarSymbolModifier())
    }
}

private struct AppAccentToolbarSymbolModifier: ViewModifier {
    @Environment(\.appAccentColor) private var appAccentColor

    func body(content: Content) -> some View {
        content
            .foregroundStyle(appAccentColor)
            .tint(appAccentColor)
    }
}
