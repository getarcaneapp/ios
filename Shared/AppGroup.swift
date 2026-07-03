import Foundation

/// App Group shared between the main app and the ArcaneWidgets extension.
/// Requires the "App Groups" capability with this identifier on BOTH targets.
nonisolated enum AppGroup {
    static let identifier = "group.com.getarcaneapp.ios.mobile"

    /// Shared defaults, nil when the entitlement is missing (e.g. before the
    /// capability is added in Xcode) — callers must degrade gracefully.
    static var defaults: UserDefaults? {
        UserDefaults(suiteName: identifier)
    }

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    /// Keys mirrored from the app's standard defaults so the widget/intents
    /// side can read them without the app's sandbox.
    enum Keys {
        static let serverURL = "arcane.serverURL"
        static let activeEnvironmentID = "arcane.activeEnvironmentID"
        static let activeEnvironmentName = "arcane.activeEnvironmentName"
        static let accentColorHex = "accentColorHex"
    }
}
