import UIKit

/// Tiny wrapper around UIKit's haptic feedback generators so call sites don't
/// need to allocate / prepare generators themselves. All methods are no-ops on
/// devices that don't support haptics (no need to gate at call sites).
enum HapticsManager {
    private static let lightImpact: UIImpactFeedbackGenerator = {
        let g = UIImpactFeedbackGenerator(style: .light)
        g.prepare()
        return g
    }()

    private static let mediumImpact: UIImpactFeedbackGenerator = {
        let g = UIImpactFeedbackGenerator(style: .medium)
        g.prepare()
        return g
    }()

    private static let notification: UINotificationFeedbackGenerator = {
        let g = UINotificationFeedbackGenerator()
        g.prepare()
        return g
    }()

    static func light() {
        MainActor.assumeIsolated {
            lightImpact.impactOccurred()
            lightImpact.prepare()
        }
    }

    static func medium() {
        MainActor.assumeIsolated {
            mediumImpact.impactOccurred()
            mediumImpact.prepare()
        }
    }

    static func success() {
        MainActor.assumeIsolated {
            notification.notificationOccurred(.success)
            notification.prepare()
        }
    }

    static func warning() {
        MainActor.assumeIsolated {
            notification.notificationOccurred(.warning)
            notification.prepare()
        }
    }

    static func error() {
        MainActor.assumeIsolated {
            notification.notificationOccurred(.error)
            notification.prepare()
        }
    }
}
