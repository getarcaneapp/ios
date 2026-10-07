import Foundation

/// Captures the preference once; an open editing session never switches beneath a draft.
nonisolated struct ComposePreviewSession {
    static let preferenceKey = "arcane.preview.nativeComposeEditor"
    let isEnabled: Bool

    init(defaults: UserDefaults = .standard) {
        isEnabled = defaults.bool(forKey: Self.preferenceKey)
    }
}
