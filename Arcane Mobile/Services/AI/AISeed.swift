import Foundation

/// Optional context the assistant is opened with from a detail screen. Drives a
/// pre-filled composer prompt and a small context banner. Unrestricted so the
/// (iOS 18) detail views can build one before the `#available` gate.
enum AISeed: Equatable, Sendable {
    case none
    case container(id: String, name: String)
    case project(id: String, name: String)

    /// Pre-filled (editable) composer text when the assistant opens.
    var initialPrompt: String? {
        switch self {
        case .none: return nil
        case let .container(_, name): return "Help me with the container “\(name)”: "
        case let .project(_, name): return "Help me with the project “\(name)”: "
        }
    }

    /// Short banner shown above the transcript.
    var contextBanner: String? {
        switch self {
        case .none: return nil
        case let .container(_, name): return "Container · \(name)"
        case let .project(_, name): return "Project · \(name)"
        }
    }
}
