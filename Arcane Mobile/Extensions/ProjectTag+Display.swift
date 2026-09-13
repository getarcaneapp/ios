import Arcane
import SwiftUI

extension ProjectTag {
    var displayColor: Color {
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
}
