import Foundation

nonisolated enum ComposeFieldPathComponent: Hashable {
    case key(String)
    case index(Int)
}

nonisolated enum ComposeNativeKind: String, CaseIterable, Identifiable {
    case string = "Text"
    case number = "Number"
    case boolean = "Boolean"
    case null = "Empty"
    case mapping = "Object"
    case sequence = "List"
    case unsupported = "Preserved"
    var id: String { rawValue }
    static var editableCases: [Self] { allCases.filter { $0 != .unsupported } }
}

nonisolated struct ComposeNativeField: Identifiable {
    let name: String
    let path: [ComposeFieldPathComponent]
    let kind: ComposeNativeKind
    let value: String
    var id: [ComposeFieldPathComponent] { path }
}
