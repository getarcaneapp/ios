import Foundation
import Arcane

struct VolumeWorkspaceDraft {
    var text = ""
    var baseline = ""
    var conflict = false
    var hasChanges: Bool { text != baseline }

    mutating func load(_ content: String) {
        text = content
        baseline = content
        conflict = false
    }

    mutating func review(latest: String) {
        baseline = latest
        conflict = false
    }

    static func validRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\0")
            && !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0 == ".." || $0 == "." }
    }
}
