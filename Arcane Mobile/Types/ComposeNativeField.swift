import Foundation

nonisolated enum ComposeFieldPathComponent: Hashable {
    case key(String)
    case index(Int)
}

nonisolated enum ComposeNativeKind: String, CaseIterable, Identifiable {
    case string = "Text", number = "Number", boolean = "Boolean", null = "Empty", mapping = "Object", sequence = "List", unsupported = "Preserved"
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
