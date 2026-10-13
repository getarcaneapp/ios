import Arcane
import SwiftUI

extension ProjectTag {
    /// Colors the server accepts for project tags.
    static let availableColors = ["gray", "purple", "blue", "green", "yellow", "orange", "red", "pink"]

    static func displayColor(for color: String) -> Color {
        switch color {
        case "purple": .purple
        case "blue": .blue
        case "green": .green
        case "yellow": .yellow
        case "orange": .orange
        case "red": .red
        case "pink": .pink
        default: .gray
        }
    }

    var displayColor: Color { Self.displayColor(for: color) }

    /// Compose-managed tags live in the compose file and can't be changed from the app.
    var isComposeManaged: Bool { sources.contains("compose") }
}
