import Foundation
import StoreKit
import UIKit
import Observation

/// Tracks user-success milestones (container starts, project ups, etc.) and
/// requests an App Store review after a configurable threshold, suppressed
/// per-app-version so users aren't prompted twice on the same build.
@Observable
final class ReviewPrompter {
    static let shared = ReviewPrompter()

    private static let actionsKey = "arcane.review.successfulActions"
    private static let lastPromptVersionKey = "arcane.review.lastPromptVersion"
    private static let threshold = 5

    private init() {}

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Call from any success branch (container start, project up, etc.).
    func recordSuccess() {
        let next = UserDefaults.standard.integer(forKey: Self.actionsKey) + 1
        UserDefaults.standard.set(next, forKey: Self.actionsKey)
    }

    /// Called from the App when the scene becomes active. Prompts if the
    /// threshold is met and the user hasn't been prompted on this version yet.
    @MainActor
    func maybePromptIfDue() {
        let actions = UserDefaults.standard.integer(forKey: Self.actionsKey)
        let lastVersion = UserDefaults.standard.string(forKey: Self.lastPromptVersionKey) ?? ""
        guard actions >= Self.threshold, lastVersion != currentVersion else { return }

        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
        else { return }

        Task {
             AppStore.requestReview(in: scene)
        }
        UserDefaults.standard.set(currentVersion, forKey: Self.lastPromptVersionKey)
    }
}
