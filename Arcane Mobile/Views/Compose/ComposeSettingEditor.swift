import SwiftUI

struct ComposeSettingEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ComposeSettingDraft
    @State private var error: String?
    let needsName: Bool
    let save: (ComposeSettingDraft) -> String?

    init(draft: ComposeSettingDraft, needsName: Bool, save: @escaping (ComposeSettingDraft) -> String?) {
        _draft = State(initialValue: draft)
        self.needsName = needsName
        self.save = save
    }

    var body: some View {
        NavigationStack {
            Form {
                if needsName { TextField("Setting name", text: $draft.name) }
                Section {
                    ComposeSettingFields(draft: $draft, root: true)
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .textFieldStyle(.plain)
            .navigationTitle(needsName ? "New setting" : ComposeDisplayText.title(draft.name))
            .navigationBarTitleDisplayMode(.inline)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        error = save(draft)
                        if error == nil { dismiss() }
                    }.disabled(needsName && draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

private struct ComposeSettingFields: View {
    @Binding var draft: ComposeSettingDraft
    var root = false
    var namedEntry = false
    @State private var expanded = false

    private var title: String { draft.name.isEmpty ? "Value" : ComposeDisplayText.title(draft.name) }
    private var choices: [ComposeNativeKind] { draft.schema?.kinds ?? ComposeNativeKind.editableCases }
    private var options: ComposeFieldOptions { ComposeFieldOptions(path: draft.schemaPath) }
    private var collection: Bool { draft.kind == .mapping || draft.kind == .sequence }

    var body: some View {
        Group {
            if !root && collection && !namedEntry {
                DisclosureGroup(isExpanded: $expanded) {
                    if expanded { contents }
                } label: { Text(title).foregroundStyle(Color.primary) }
                    .onChange(of: expanded) { _, open in if open { draft.prepareFields() } }
            } else if namedEntry && (draft.kind == .string || draft.kind == .number) && options.values.isEmpty {
                HStack {
                    TextField("Name", text: $draft.name)
                        .accessibilityLabel("Name")
                    TextField("Value", text: $draft.value)
                        .multilineTextAlignment(.trailing)
                        .accessibilityLabel("Value")
                }
                .onChange(of: draft.name) { _, _ in updateEntry() }
                .onChange(of: draft.value) { _, _ in updateEntry() }
            } else { contents }
        }
        .contextMenu {
            if choices.count > 1 { formatPicker }
        }
    }

    private func updateEntry() {
        draft.included = !draft.name.isEmpty || !draft.value.isEmpty
    }

    @ViewBuilder private var contents: some View {
        if root, let description = description, !description.isEmpty {
            Text(description).font(.subheadline).foregroundStyle(Color.secondary)
        }
        if namedEntry {
            LabeledContent("Name") {
                TextField("Name", text: $draft.name)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .onChange(of: draft.name) { _, _ in draft.included = !draft.name.isEmpty || !draft.value.isEmpty }
            }
        }
        switch draft.kind {
        case .mapping:
            ForEach($draft.children) { $child in
                AnyView(ComposeSettingFields(draft: $child, namedEntry: draft.fields.isEmpty))
            }
            .onDelete { indices in draft.children.remove(atOffsets: indices) }
            .deleteDisabled(!draft.fields.isEmpty)
            if draft.fields.isEmpty {
                Button("Add entry", systemImage: "plus") { draft.appendEntry() }.buttonStyle(.borderless)
            }
        case .sequence:
            ForEach($draft.children) { $child in
                AnyView(ComposeSettingFields(draft: $child, root: true))
            }
            .onDelete { indices in draft.children.remove(atOffsets: indices) }
            Button("Add item", systemImage: "plus") { draft.appendEntry() }.buttonStyle(.borderless)
        case .boolean:
            Toggle(title, isOn: Binding(get: { draft.value == "true" }, set: { enabled in
                draft.value = String(enabled)
                draft.included = true
            }))
        case .string, .number:
            if !options.values.isEmpty {
                ComposeValuePicker(title: title, options: options, value: Binding(get: { draft.value }, set: { value in
                    draft.value = value
                    draft.included = !value.isEmpty
                }))
            } else {
                LabeledContent(namedEntry ? "Value" : title) {
                        TextField(placeholder, text: $draft.value)
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(draft.kind == .number ? .numbersAndPunctuation : .default)
                            .accessibilityLabel(namedEntry ? "Value" : title)
                            .onChange(of: draft.value) { _, _ in
                                draft.included = namedEntry ? !draft.name.isEmpty || !draft.value.isEmpty : !draft.value.isEmpty
                            }
                }
            }

        case .null: Text("Leave this setting empty.").foregroundStyle(Color.secondary)
        case .unsupported: Text("This value can't be edited here.").foregroundStyle(Color.secondary)
        }
    }

    private var formatPicker: some View {
        Picker("Enter as", selection: Binding(get: { draft.kind }, set: { kind in
            draft.kind = kind
            draft.value = ""
            draft.children = []
            draft.included = false
            draft.prepareFields()
        })) {
            ForEach(choices) { kind in Text(formatName(kind)).tag(kind) }
        }
    }

    private var placeholder: String {
        switch draft.name {
        case "icon", "icons", "icon-light", "icon-dark": "Icon name or image URL"
        case "urls": "https://example.com"
        default: "Value"
        }
    }

    private var description: String? {
        switch draft.name {
        case "annotations": "Add names and values for tools that use this service."
        case "x-arcane": "Choose how this appears in Arcane. Fill in only the settings you need."
        case "labels": "Add labels as names and values."
        default: draft.schema?.description
        }
    }

    private func formatName(_ kind: ComposeNativeKind) -> String {
        switch kind {
        case .mapping: draft.fields.isEmpty ? "Name and value pairs" : "Fill in fields"
        case .sequence: "List of values"
        case .boolean: "On or off"
        case .string: "Text or variable"
        case .null: "No value"
        default: kind.rawValue
        }
    }
}
