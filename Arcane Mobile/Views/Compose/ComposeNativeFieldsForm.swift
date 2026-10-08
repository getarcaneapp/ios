import SwiftUI

/// Native access to ordinary Compose fields, including nested objects and lists.
struct ComposeNativeFieldsForm: View {
    @Binding var text: String
    private let fieldPath: [ComposeFieldPathComponent]
    private let schemaPath: [ComposeFieldPathComponent]
    let title: String
    let readOnly: Bool
    let excluding: Set<String>
    @State private var editing: ComposeNativeField?
    @State private var simpleEditing: ComposeNativeField?
    @State private var simpleValue = ""
    @FocusState private var valueFocused: Bool
    @State private var adding = false
    @State private var error: String?

    init(text: Binding<String>, path: [String], title: String, readOnly: Bool, excluding: Set<String> = [], schemaPath: [ComposeFieldPathComponent]? = nil) {
        _text = text
        fieldPath = path.map(ComposeFieldPathComponent.key)
        self.title = title
        self.readOnly = readOnly
        self.excluding = excluding
        self.schemaPath = schemaPath ?? fieldPath
    }

    private init(text: Binding<String>, fieldPath: [ComposeFieldPathComponent], schemaPath: [ComposeFieldPathComponent], title: String, readOnly: Bool) {
        _text = text
        self.fieldPath = fieldPath
        self.schemaPath = schemaPath
        self.title = title
        self.readOnly = readOnly
        excluding = []
    }

    private var document: ComposeDocument? { try? ComposeDocument(text) }
    private var current: ComposeNativeField? { document?.nativeField(at: fieldPath, name: title) }
    private var excludedNames: Set<String> { excluding }
    private var fields: [ComposeNativeField] {
        (document?.nativeFields(at: fieldPath) ?? []).filter { !excludedNames.contains($0.name) }
    }
    private var isCollection: Bool { current?.kind == .mapping || current?.kind == .sequence }

    var body: some View {
        Form {
            if let current {
                if isCollection {
                    ForEach(fields) { field in row(field) }
                        .onDelete { indices in
                            guard !readOnly else { return }
                            mutate { document in
                                var result = document.source
                                for index in indices.reversed() { result = try ComposeDocument(result).removingNative(at: fields[index].path) }
                                return result
                            }
                        }.deleteDisabled(readOnly || simpleEditing != nil)
                    if fields.isEmpty {
                        Text(current.kind == .sequence ? "No items" : "No fields")
                            .foregroundStyle(.secondary)
                    }
                } else if current.kind == .null {
                    Text("No value configured").foregroundStyle(.secondary)
                    if !readOnly {
                        Button("Set value") { editing = current }
                    }
                } else {
                    row(current)
                }
            } else {
                Text("The document has a syntax error. Your text is preserved.")
                    .foregroundStyle(.secondary)
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle(ComposeDisplayText.title(title))
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .toolbar {
            if !readOnly && (isCollection || current?.kind == .null) {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Add", systemImage: "plus") { adding = true }
                    } label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel("Configuration actions")
                }
            }
        }
        .sheet(item: $editing) { field in
            ComposeNativeValueSheet(title: field.name, kind: field.kind, value: field.value, needsName: false) { _, kind, value in
                save(field, kind: kind, value: value)
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $adding) {
            ComposeAddFieldsSheet(text: $text, fieldPath: fieldPath, excluding: excludedNames, schemaPath: schemaPath)
        }
    }

    @ViewBuilder private func row(_ field: ComposeNativeField) -> some View {
        switch field.kind {
        case .mapping, .sequence:
            NavigationLink {
                ComposeNativeFieldsForm(text: $text, fieldPath: field.path, schemaPath: schemaPath + field.path.dropFirst(fieldPath.count), title: field.name, readOnly: readOnly)
            } label: {
                LabeledContent(ComposeDisplayText.title(field.name), value: field.kind.rawValue)
            }
        case .unsupported:
            VStack(alignment: .leading, spacing: 4) {
                Text(ComposeDisplayText.title(field.name))
                Text("Unavailable")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        case .boolean:
            Toggle(ComposeDisplayText.title(field.name), isOn: Binding(
                get: { document?.nativeField(at: field.path).value.lowercased() == "true" },
                set: { value in mutate { try $0.settingNative(String(value), kind: .boolean, at: field.path) } }
            )).disabled(readOnly)
        default:
            let options = ComposeFieldOptions(path: schemaPath + field.path.dropFirst(fieldPath.count))
            if simpleEditing?.id != field.id, (field.kind == .string || field.kind == .number), !options.values.isEmpty {
                Picker(ComposeDisplayText.title(field.name), selection: Binding(
                    get: { document?.nativeField(at: field.path).value ?? field.value },
                    set: { value in
                        if value == "__custom__" {
                            simpleValue = field.value
                            simpleEditing = field
                            valueFocused = true
                        } else { mutate { try $0.settingNative(value, kind: field.kind, at: field.path) } }
                    }
                )) {
                    if !options.values.contains(field.value) { Text(field.value).tag(field.value) }
                    ForEach(options.values, id: \.self) { Text(options.label($0)).tag($0) }
                    if options.allowsCustom { Text("Custom value…").tag("__custom__") }
                }.disabled(readOnly)
            } else if simpleEditing?.id == field.id {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent(ComposeDisplayText.title(field.name)) {
                    TextField("Value", text: $simpleValue)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(field.kind == .number ? .numbersAndPunctuation : .default)
                        .focused($valueFocused)
                        .accessibilityLabel(ComposeDisplayText.title(field.name))
                        .disabled(readOnly)
                    }
                    HStack {
                        Spacer()
                        Button("Cancel") {
                            valueFocused = false
                            simpleEditing = nil
                        }
                        Button("Apply") {
                            guard let original = simpleEditing else { return }
                            error = save(original, kind: original.kind, value: simpleValue)
                            if error == nil {
                                valueFocused = false
                                simpleEditing = nil
                            }
                        }.buttonStyle(.borderedProminent)
                    }
                    .buttonStyle(.borderless)
                }.padding(.vertical, 4)
            } else {
                Button {
                    if (field.kind == .string || field.kind == .number), !field.value.contains("\n"), !field.value.contains("\r"), field.value.count <= 160 {
                        simpleValue = field.value
                        simpleEditing = field
                        valueFocused = true
                    } else {
                        editing = field
                    }
                } label: {
                    LabeledContent(ComposeDisplayText.title(field.name), value: field.kind == .null ? "Empty" : field.value)
                        .lineLimit(3)
                        .foregroundStyle(Color.primary)
                }.disabled(readOnly || simpleEditing != nil)
            }
        }
    }

    private func save(_ field: ComposeNativeField, kind: ComposeNativeKind, value: String) -> String? {
        guard !readOnly else { return nil }
        return apply { document in
            guard document.nativeField(at: field.path).kind == field.kind,
                  document.nativeField(at: field.path).value == field.value else { throw ComposeFormError.changed }
            return try document.settingNative(value, kind: kind, at: field.path)
        }
    }

    private func apply(_ action: (ComposeDocument) throws -> String) -> String? {
        do { text = try action(ComposeDocument(text)); error = nil; return nil }
        catch { return error.localizedDescription }
    }
    private func mutate(_ action: (ComposeDocument) throws -> String) {
        error = apply(action)
    }
}

private struct ComposeNativeValueSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let needsName: Bool
    let save: (String, ComposeNativeKind, String) -> String?
    @State private var name = ""
    @State private var kind: ComposeNativeKind
    @State private var value: String
    @State private var error: String?

    init(title: String, kind: ComposeNativeKind, value: String, needsName: Bool, save: @escaping (String, ComposeNativeKind, String) -> String?) {
        self.title = title
        self.needsName = needsName
        self.save = save
        _kind = State(initialValue: kind)
        _value = State(initialValue: value)
    }

    var body: some View {
        NavigationStack {
            Form {
                if needsName { TextField("Name", text: $name) }
                if needsName || kind == .null {
                    Picker("Type", selection: $kind) {
                        ForEach(ComposeNativeKind.editableCases) { kind in Text(kind.rawValue).tag(kind) }
                    }
                }
                switch kind {
                case .string: TextField("Value", text: $value, axis: .vertical).lineLimit(3...12)
                case .number: TextField("Value", text: $value).keyboardType(.numbersAndPunctuation)
                case .boolean:
                    Toggle("Enabled", isOn: Binding(get: { value.lowercased() == "true" }, set: { value = String($0) }))
                case .mapping: Text("Add fields after creating this object.").foregroundStyle(.secondary)
                case .sequence: Text("Add items after creating this list.").foregroundStyle(.secondary)
                case .null: Text("Store an empty value.").foregroundStyle(.secondary)
                case .unsupported: EmptyView()
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .navigationTitle(ComposeDisplayText.title(title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        error = save(name, kind, value)
                        if error == nil { dismiss() }
                    }.disabled(needsName && name.isEmpty)
                }
            }
        }
    }
}
