import Foundation
import Arcane

nonisolated enum ActivityToastScope: String, CaseIterable, Identifiable, Sendable {
    case userInitiated
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .userInitiated:
            return "User Initiated"
        case .all:
            return "All Activities"
        }
    }

    var subtitle: String {
        switch self {
        case .userInitiated:
            return "Only work started by a user"
        case .all:
            return "User, automated, and system work"
        }
    }

    func includes(_ activity: Activity) -> Bool {
        guard self == .userInitiated else { return true }
        guard let startedBy = activity.startedBy else { return false }

        let userID = startedBy.userId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !userID.isEmpty { return true }

        // Older v2 servers may omit the user ID, so retain a username fallback
        // while still excluding the backend's explicit system actor.
        let username = startedBy.username.trimmingCharacters(in: .whitespacesAndNewlines)
        return !username.isEmpty && username.localizedCaseInsensitiveCompare("System") != .orderedSame
    }
}
