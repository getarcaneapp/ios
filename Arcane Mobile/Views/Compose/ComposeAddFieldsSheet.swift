import SwiftUI

/// Uses the Compose specification to offer fields without exposing YAML syntax.
struct ComposeAddFieldsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var text: String
    let fieldPath: [ComposeFieldPathComponent]
    let schemaPath: [ComposeFieldPathComponent]
    let excluding: Set<String>
    @State private var search = ""
    @State private var choosingValue = false
    @State private var selected: ComposeSchemaField?
    @State private var name = ""
    @State private var kind: ComposeNativeKind = .string
    @State private var value = ""
    @State private var error: String?
    @FocusState private var valueFocused: Bool

    init(text: Binding<String>, path: [String], excluding: Set<String> = [], schemaPath: [ComposeFieldPathComponent]? = nil) {
        _text = text
        fieldPath = path.map(ComposeFieldPathComponent.key)
        self.excluding = excluding
        self.schemaPath = schemaPath ?? fieldPath
    }

    init(text: Binding<String>, fieldPath: [ComposeFieldPathComponent], excluding: Set<String> = [], schemaPath: [ComposeFieldPathComponent]? = nil) {
        _text = text
        self.fieldPath = fieldPath
        self.excluding = excluding
        self.schemaPath = schemaPath ?? fieldPath
    }

    private var isList: Bool { (try? ComposeDocument(text))?.nativeField(at: fieldPath).kind == .sequence }
    private var excludedNames: Set<String> {
        if schemaPath.count == 2, let first = schemaPath.first, case .key(let root) = first, ["services", "jobs"].contains(root) {
            return excluding.union(["build", "deploy"])
        }
        return excluding
    }
    private var available: [ComposeSchemaField] {
        let existing = Set((try? ComposeDocument(text))?.nativeFields(at: fieldPath).map(\.name) ?? [])
        return ComposeSchema.fields(at: schemaPath).filter {
            !existing.contains($0.name) && !excludedNames.contains($0.name)
                && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.description.localizedCaseInsensitiveContains(search))
        }
    }
    private var kinds: [ComposeNativeKind] {
        let permitted = selected?.kinds ?? []
        return permitted.isEmpty ? ComposeNativeKind.editableCases : permitted
    }

    var body: some View {
        NavigationStack {
            Group {
                if choosingValue || isList {
                    valueForm
                } else {
                    List {
                        ForEach(available, id: \.name) { field in
                            Button { select(field) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(ComposeDisplayText.title(field.name)).foregroundStyle(.primary)
                                    if !field.description.isEmpty {
                                        Text(field.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }.padding(.vertical, 3)
                            }
                        }
                        Button("Custom field", systemImage: "plus") { select(nil) }
                    }.searchable(text: $search, prompt: "Find a Compose setting")
                }
            }
            .navigationTitle(isList ? "Add item" : choosingValue ? (selected.map { ComposeDisplayText.title($0.name) } ?? "Custom Field") : "Add configuration")
            .navigationBarTitleDisplayMode(.inline)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(choosingValue && !isList ? "Back" : "Cancel") {
                        if choosingValue && !isList { choosingValue = false; error = nil }
                        else { dismiss() }
                    }
                }
                if choosingValue || isList {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add", action: add).disabled(!isList && name.isEmpty)
                    }
                }
            }
            .onAppear {
                if isList { select(ComposeSchema.value(at: schemaPath + [.index(0)])) }
            }
        }
    }

    private var valueForm: some View {
        Form {
            if !isList && selected == nil { TextField("Field name", text: $name) }
            if kinds.count > 1 {
                Picker("Value type", selection: $kind) {
                    ForEach(kinds) { Text($0.rawValue).tag($0) }
                }
            }
            switch kind {
            case .string, .number:
                if let values = selected?.enumValues, !values.isEmpty {
                    Picker("Value", selection: $value) {
                        ForEach(values, id: \.self) { Text(ComposeDisplayText.title($0)).tag($0) }
                    }
                } else {
                    TextField("Value", text: $value, axis: .vertical)
                        .keyboardType(kind == .number ? .numbersAndPunctuation : .default)
                        .focused($valueFocused)
                }
            case .boolean:
                Toggle("Enabled", isOn: Binding(get: { value == "true" }, set: { value = String($0) }))
            case .mapping: Text("Add its settings after creating this section.").foregroundStyle(.secondary)
            case .sequence: Text("Add its entries after creating this section.").foregroundStyle(.secondary)
            case .null: Text("Use an empty value.").foregroundStyle(.secondary)
            case .unsupported: EmptyView()
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
    }

    private func select(_ field: ComposeSchemaField?) {
        selected = field
        name = field?.name ?? ""
        kind = field?.preferredKind ?? .string
        value = field?.enumValues.first ?? (kind == .boolean ? "false" : "")
        error = nil
        choosingValue = true
    }

    private func add() {
        do {
            guard !excludedNames.contains(name) else { throw ComposeFormError.invalid("This setting is managed outside this editor.") }
            text = try ComposeDocument(text).addingNative(value, kind: kind, key: isList ? nil : name, at: fieldPath)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
