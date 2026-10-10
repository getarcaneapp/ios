import Foundation

/// Uncommitted form values. Serialization uses the existing source-preserving editor.
nonisolated struct ComposeSettingDraft: Identifiable {
    let id = UUID()
    var name: String
    var kind: ComposeNativeKind
    var value = ""
    var children: [ComposeSettingDraft] = []
    var included = false
    let schemaPath: [ComposeFieldPathComponent]

    init(name: String, schemaPath: [ComposeFieldPathComponent], included: Bool = false) {
        self.name = name
        self.schemaPath = schemaPath
        self.included = included
        let field = ComposeSchema.value(at: schemaPath)
        kind = field?.preferredKind ?? .string
        if field?.kinds.contains(.mapping) == true, !ComposeSchema.fields(at: schemaPath).isEmpty {
            kind = .mapping
        }
    }

    var schema: ComposeSchemaField? { ComposeSchema.value(at: schemaPath) }
    var isConfigured: Bool { included || !value.isEmpty || children.contains(where: \.isConfigured) }
    var fields: [ComposeSchemaField] { ComposeSchema.fields(at: schemaPath) }

    mutating func prepareFields() {
        guard children.isEmpty else { return }
        if kind == .mapping {
            children = fields.map { Self(name: $0.name, schemaPath: schemaPath + [.key($0.name)]) }
            if children.isEmpty { appendEntry() }
        } else if kind == .sequence {
            appendEntry()
        }
    }

    mutating func appendEntry() {
        let path = schemaPath + (kind == .sequence ? [.index(children.count)] : [.key("entry")])
        var entry = Self(name: "", schemaPath: path)
        // Entries in a free-form dictionary start as ordinary name/value pairs.
        if kind == .mapping { entry.kind = .string }
        entry.prepareFields()
        children.append(entry)
    }

    func adding(
        to source: String, at parent: [ComposeFieldPathComponent], newService: String? = nil, listItem: Bool = false
    ) throws -> String {
        let value = kind == .boolean && value.isEmpty ? "false" : value
        if kind == .string || kind == .number, let options = schema?.enumValues, !options.isEmpty,
            !options.contains(value)
        {
            throw ComposeFormError.invalid("Choose a value for \(name).")
        }
        let document = try ComposeDocument(source)
        let path: [ComposeFieldPathComponent]
        let result: String
        if let newService {
            result = try document.addingService(newService, field: name, value: value, kind: kind)
            path = [.key("services"), .key(newService), .key(name)]
        } else {
            let key = listItem ? nil : name
            if !listItem, name.isEmpty { throw ComposeFormError.invalid("Enter a name for this setting.") }
            path = parent + (listItem ? [.index(document.nativeFields(at: parent).count)] : [.key(name)])
            result = try document.addingNative(value, kind: kind, key: key, at: parent)
        }
        return try addingChildren(to: result, at: path)
    }

    private func addingChildren(to source: String, at path: [ComposeFieldPathComponent]) throws -> String {
        var result = source
        for child in children where child.isConfigured {
            result = try child.adding(to: result, at: path, listItem: kind == .sequence)
        }
        return result
    }
}
