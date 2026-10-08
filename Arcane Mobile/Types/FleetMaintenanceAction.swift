import Foundation

enum FleetMaintenanceAction: String, Identifiable {
    case update, checkImages
    var id: String { rawValue }
    var title: String {
        switch self {
        case .update: "Update All"
        case .checkImages: "Check All"
        }
    }
    var buttonTitle: String {
        switch self {
        case .update: "Update All"
        case .checkImages: "Check All"
        }
    }
    var explanation: String {
        switch self {
        case .update: "Run the configured container and project updater on every enabled environment. Containers may restart during updates."
        case .checkImages: "Check images in every enabled environment for available updates. This does not install updates."
        }
    }
}
