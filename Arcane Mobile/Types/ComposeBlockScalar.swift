import Foundation

/// The semantic value and source extent of a literal or folded YAML scalar.
nonisolated struct ComposeBlockScalar {
    let value: String
    let replacementRange: NSRange
    let indentation: Int
    let parentIndentation: Int
    let explicitIndentation: Int?
    let headerSuffix: String
}
