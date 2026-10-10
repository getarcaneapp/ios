import SwiftUI

/// Native fields write only the selected source node, preserving neighboring YAML.
struct ComposeScalarField: View {
    @Binding var text: String
    let path: [String]
    let title: String
    let readOnly: Bool
    var integer = false
    @State private var error: String?

    var body: some View {
        let nativePath = path.map(ComposeFieldPathComponent.key)
        let field = (try? ComposeDocument(text))?.nativeField(at: nativePath)
        if let field, [.string, .number, .boolean, .null].contains(field.kind) {
            let options = ComposeFieldOptions(path: nativePath)
            let input = Binding<String>(
                get: {
                    let current = (try? ComposeDocument(text))?.nativeField(at: nativePath)
                    return current?.kind == .null ? "" : current?.value ?? ""
                },
                set: { value in
                    guard !readOnly else { return }
                    do {
                        let document = try ComposeDocument(text)
                        if integer, value.isEmpty {
                            if document.nativeFields(at: Array(nativePath.dropLast())).contains(where: {
                                $0.path == nativePath
                            }) {
                                text = try document.removingNative(at: nativePath)
                            }
                        } else {
                            if integer {
                                guard let number = Int(value), number >= 0 else {
                                    throw ComposeFormError.invalid("Enter a nonnegative whole number.")
                                }
                            }
                            text = try document.settingNative(value, kind: integer ? .number : .string, at: nativePath)
                        }
                        error = nil
                    } catch { self.error = error.localizedDescription }
                }
            )
            if options.values.isEmpty {
                LabeledContent(title) {
                    TextField(title, text: input)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .disabled(readOnly)
                }
            } else {
                ComposeValuePicker(title: title, options: options, value: input).disabled(readOnly)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        } else {
            LabeledContent(title, value: "Unavailable")
        }
    }

}

struct ComposeStringListForm: View {
    @Binding var text: String
    let path: [String]
    let title: String
    let readOnly: Bool
    var allowsScalar = true
    var environmentFiles = false
    @State private var newValue = ""
    @FocusState private var focused: Bool
    @State private var adding = false
    @State private var error: String?
    private var document: ComposeDocument? { try? ComposeDocument(text) }

    private var needsNativeFields: Bool {
        guard let document else { return false }
        let kind = document.nativeField(at: path.map(ComposeFieldPathComponent.key)).kind
        if kind == .sequence,
            !ComposeFieldOptions(path: path.map(ComposeFieldPathComponent.key) + [.index(0)]).values.isEmpty
        {
            return true
        }
        return kind != .null
            && (!document.isEditable(at: path) || document.rawValue(at: path) == nil
                || (kind == .string && document.scalar(at: path) == nil))
    }

    var body: some View {
        Group {
            if needsNativeFields {
                ComposeNativeFieldsForm(text: $text, path: path, title: title, readOnly: readOnly)
            } else {
                Form {
                    Section(title) { fields }
                    if let error { Text(error).foregroundStyle(.red) }
                }.navigationTitle(title)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .toolbar {
                        if !readOnly {
                            ToolbarItem(placement: .primaryAction) {
                                Button("Add", systemImage: "plus") {
                                    newValue = ""
                                    error = nil
                                    adding = true
                                }
                            }
                        }
                    }
                    .sheet(isPresented: $adding) { addSheet }
            }
        }
    }

    @ViewBuilder var fields: some View {
        if let document, document.isEditable(at: path), let items = document.items(at: path) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, raw in
                if let value = decoded(raw) {
                    TextField(
                        "Value",
                        text: Binding(
                            get: {
                                guard let current = self.document?.items(at: path), current.indices.contains(index)
                                else { return value }
                                return decoded(current[index]) ?? value
                            },
                            set: { value in
                                change { try $0.settingItem(ComposeDocument.quoted(value), at: path, index: index) }
                            })
                    ).disabled(readOnly)
                } else if environmentFiles, let entry = try? ComposeDocument(raw),
                    entry.nativeField(at: []).kind == .mapping
                {
                    NavigationLink(entry.scalar(at: ["path"]) ?? "Environment file") {
                        ComposeEnvironmentFileEntry(
                            text: itemBinding(index, original: raw), readOnly: readOnly,
                            schemaPath: path.map(ComposeFieldPathComponent.key) + [.index(index)])
                    }
                } else {
                    LabeledContent("Value", value: "Unsupported value")
                }
            }.onDelete { indices in
                guard !readOnly else { return }
                do {
                    var source = text
                    for index in indices.reversed() {
                        source = try ComposeDocument(source).removingItem(at: path, index: index)
                    }
                    text = source
                    error = nil
                } catch { self.error = error.localizedDescription }
            }.deleteDisabled(readOnly)
        } else if let document, document.isEditable(at: path), allowsScalar,
            let scalar = document.scalar(at: path), scalar != "null", scalar != "~"
        {
            ComposeScalarField(text: $text, path: path, title: "Value", readOnly: readOnly)
                .swipeActions {
                    if !readOnly { Button("Delete", role: .destructive) { change { try $0.removing(at: path) } } }
                }
        } else if document?.rawValue(at: path) == nil {
            EmptyView()
        } else {
            Text("Unsupported format").foregroundStyle(.secondary)
        }
    }

    private var addSheet: some View {
        NavigationStack {
            Form {
                LabeledContent("Value") {
                    TextField("Value", text: $newValue).focused($focused)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Add value")
            .task { focused = true }
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { adding = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        change { document in
                            if let scalar = document.scalar(at: path) {
                                return try document.setting(
                                    "- " + ComposeDocument.quoted(scalar) + "\n- " + ComposeDocument.quoted(newValue),
                                    at: path)
                            }
                            return try document.appendingItem(ComposeDocument.quoted(newValue), at: path)
                        }
                        if error == nil {
                            adding = false
                            newValue = ""
                        }
                    }.disabled(newValue.isEmpty)
                }
            }
        }
    }
    private func itemBinding(_ index: Int, original: String) -> Binding<String> {
        Binding(
            get: {
                guard let items = document?.items(at: path), items.indices.contains(index) else { return original }
                return items[index]
            },
            set: { raw in
                change { try $0.settingItem(raw, at: path, index: index) }
            })
    }
    private func decoded(_ raw: String) -> String? { (try? ComposeDocument("value: " + raw))?.scalar(at: ["value"]) }
    private func change(_ action: (ComposeDocument) throws -> String) {
        guard !readOnly else { return }
        do {
            text = try action(ComposeDocument(text))
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

struct ComposeHealthcheckForm: View {
    @Binding var text: String
    let path: [String]
    let readOnly: Bool
    @State private var adding = false
    private var fields: Set<String> {
        Set(((try? ComposeDocument(text))?.nativeFields(at: path.map(ComposeFieldPathComponent.key)) ?? []).map(\.name))
    }

    var body: some View {
        Form {
            if fields.contains("test") {
                Section("Command") {
                    if (try? ComposeDocument(text))?.scalar(at: path + ["test"]) != nil {
                        ComposeScalarField(
                            text: $text, path: path + ["test"], title: "Shell command", readOnly: readOnly)
                    } else {
                        NavigationLink("Command arguments") {
                            ComposeStringListForm(
                                text: $text, path: path + ["test"], title: "Command arguments", readOnly: readOnly,
                                allowsScalar: false)
                        }
                    }
                }
            }
            if !fields.isDisjoint(with: ["interval", "timeout", "start_period", "start_interval", "retries", "disable"])
            {
                Section("Timing") {
                    if fields.contains("interval") {
                        ComposeScalarField(
                            text: $text, path: path + ["interval"], title: "Interval", readOnly: readOnly)
                    }
                    if fields.contains("timeout") {
                        ComposeScalarField(text: $text, path: path + ["timeout"], title: "Timeout", readOnly: readOnly)
                    }
                    if fields.contains("start_period") {
                        ComposeScalarField(
                            text: $text, path: path + ["start_period"], title: "Start period", readOnly: readOnly)
                    }
                    if fields.contains("start_interval") {
                        ComposeScalarField(
                            text: $text, path: path + ["start_interval"], title: "Start interval", readOnly: readOnly)
                    }
                    if fields.contains("retries") {
                        ComposeScalarField(
                            text: $text, path: path + ["retries"], title: "Retries", readOnly: readOnly, integer: true)
                    }
                    if fields.contains("disable") {
                        ComposeBooleanField(text: $text, path: path + ["disable"], title: "Disable", readOnly: readOnly)
                    }
                }
            }
            if fields.isEmpty {
                ContentUnavailableView("No healthcheck settings", systemImage: "heart.text.clipboard")
            } else {
                NavigationLink("All healthcheck settings") {
                    ComposeNativeFieldsForm(text: $text, path: path, title: "Healthcheck settings", readOnly: readOnly)
                }
            }
        }.navigationTitle("Healthcheck")
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .toolbar {
                if !readOnly {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button("Add configuration", systemImage: "plus") { adding = true }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                    }
                }
            }
            .sheet(isPresented: $adding) { ComposeAddFieldsSheet(text: $text, path: path) }
    }
}

struct ComposeNetworkAttachmentsForm: View {
    @Binding var text: String
    let path: [String]
    let readOnly: Bool
    @State private var name = ""
    @FocusState private var focused: Bool
    @State private var adding = false
    @State private var addingDetails = false
    @State private var showResources = false
    @State private var externalResource: String?
    @State private var error: String?
    private var document: ComposeDocument? { try? ComposeDocument(text) }
    private var names: [String]? {
        guard let document else { return nil }
        if let items = document.items(at: path) {
            let values = items.compactMap { (try? ComposeDocument("name: " + $0))?.scalar(at: ["name"]) }
            return values.count == items.count ? values : nil
        }
        let nativePath = path.map(ComposeFieldPathComponent.key)
        guard [.mapping, .null].contains(document.nativeField(at: nativePath).kind) else { return nil }
        return document.nativeFields(at: nativePath).map(\.name)
    }

    var body: some View {
        Form {
            if let names {
                Section("Network attachments") {
                    ForEach(Array(names.enumerated()), id: \.offset) { _, key in
                        NavigationLink(key) { detail(key) }
                    }.onDelete { indices in
                        guard !readOnly else { return }
                        change { _ in
                            var source = text
                            for index in indices.reversed() {
                                let current = try ComposeDocument(source)
                                if current.items(at: path) != nil {
                                    source = try current.removingItem(at: path, index: index)
                                } else {
                                    source = try current.removingNative(
                                        at: (path + [names[index]]).map(ComposeFieldPathComponent.key))
                                }
                            }
                            return source
                        }
                    }.deleteDisabled(readOnly)
                }
            } else {
                NavigationLink("Network settings") {
                    ComposeNativeFieldsForm(text: $text, path: path, title: "Network settings", readOnly: readOnly)
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle("Networks")
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .toolbar {
                if !readOnly, names != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Add", systemImage: "plus") {
                            name = ""
                            externalResource = nil
                            error = nil
                            adding = true
                        }
                    }
                }
            }
            .sheet(isPresented: $adding) { addSheet }
    }

    private var addSheet: some View {
        NavigationStack {
            Form {
                VStack(alignment: .leading) {
                    Text("Network name").font(.caption).foregroundStyle(.secondary)
                    TextField("Network name", text: $name).focused($focused)
                }
                Button("Choose existing network") { showResources = true }
                if let error { Text(error).foregroundStyle(.red) }
            }.navigationTitle("Add network")
                .task { focused = true }
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { adding = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add") {
                            change { document in
                                guard !(names ?? []).contains(name) else { throw ComposeFormError.duplicate }
                                var source: String
                                if document.items(at: path) != nil {
                                    source = try document.appendingItem(ComposeDocument.quoted(name), at: path)
                                } else {
                                    source = try document.addingNative(
                                        "", kind: .mapping, key: name, at: path.map(ComposeFieldPathComponent.key))
                                }
                                let updated = try ComposeDocument(source)
                                if externalResource == name {
                                    if updated.rawValue(at: ["networks", name]) == nil {
                                        source = try updated.setting("external: true", at: ["networks", name])
                                    } else if updated.scalar(at: ["networks", name, "external"]) != "true" {
                                        throw ComposeFormError.invalid(
                                            "This name already has a project network definition.")
                                    }
                                } else if !updated.keys(at: ["networks"]).contains(name) {
                                    source = try updated.setting("{}", at: ["networks", name])
                                }
                                return source
                            }
                            if error == nil {
                                adding = false
                                name = ""
                            }
                        }.disabled(
                            name.isEmpty || name.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) == nil)
                    }
                }
                .sheet(isPresented: $showResources) {
                    ComposeResourcePicker(
                        kind: .network,
                        selection: Binding(
                            get: { name },
                            set: {
                                name = $0
                                externalResource = $0
                            }
                        ))
                }
        }
    }

    // Render short attachments as mappings without changing the bound document until an edit.
    private var attachmentSource: Binding<String> {
        Binding(
            get: {
                (try? ComposeDocument(text).convertingNetworkAttachments(at: path)) ?? text
            },
            set: { source in
                guard !readOnly else { return }
                text = source
            })
    }

    private func detail(_ key: String) -> some View {
        let detailPath = path + [key]
        let fields = Set(
            ((try? ComposeDocument(attachmentSource.wrappedValue))?.nativeFields(
                at: detailPath.map(ComposeFieldPathComponent.key)) ?? []).map(\.name))
        return Form {
            if !fields.isDisjoint(with: ["ipv4_address", "ipv6_address", "mac_address", "interface_name"]) {
                Section("Addresses") {
                    if fields.contains("ipv4_address") {
                        ComposeScalarField(
                            text: attachmentSource, path: detailPath + ["ipv4_address"], title: "IPv4 address",
                            readOnly: readOnly)
                    }
                    if fields.contains("ipv6_address") {
                        ComposeScalarField(
                            text: attachmentSource, path: detailPath + ["ipv6_address"], title: "IPv6 address",
                            readOnly: readOnly)
                    }
                    if fields.contains("mac_address") {
                        ComposeScalarField(
                            text: attachmentSource, path: detailPath + ["mac_address"], title: "MAC address",
                            readOnly: readOnly)
                    }
                    if fields.contains("interface_name") {
                        ComposeScalarField(
                            text: attachmentSource, path: detailPath + ["interface_name"], title: "Interface name",
                            readOnly: readOnly)
                    }
                }
            }
            if !fields.isDisjoint(with: ["aliases", "priority", "gw_priority"]) {
                Section("Options") {
                    if fields.contains("aliases") {
                        NavigationLink("Aliases") {
                            ComposeStringListForm(
                                text: attachmentSource, path: detailPath + ["aliases"], title: "Aliases",
                                readOnly: readOnly, allowsScalar: false)
                        }
                    }
                    if fields.contains("priority") {
                        ComposeScalarField(
                            text: attachmentSource, path: detailPath + ["priority"], title: "Priority",
                            readOnly: readOnly, integer: true)
                    }
                    if fields.contains("gw_priority") {
                        ComposeScalarField(
                            text: attachmentSource, path: detailPath + ["gw_priority"], title: "Gateway priority",
                            readOnly: readOnly, integer: true)
                    }
                }
            }
            if fields.isEmpty {
                ContentUnavailableView("No attachment settings", systemImage: "network")
            } else {
                NavigationLink("All network settings") {
                    ComposeNativeFieldsForm(
                        text: attachmentSource, path: detailPath, title: "Network settings", readOnly: readOnly)
                }
            }
        }.navigationTitle(key)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .toolbar {
                if !readOnly {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button("Add configuration", systemImage: "plus") { addingDetails = true }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                    }
                }
            }
            .sheet(isPresented: $addingDetails) { ComposeAddFieldsSheet(text: attachmentSource, path: detailPath) }
    }
    private func change(_ action: (ComposeDocument) throws -> String) {
        guard !readOnly else { return }
        do {
            text = try action(ComposeDocument(text))
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

struct ComposeBooleanField: View {
    @Binding var text: String
    let path: [String]
    let title: String
    let readOnly: Bool
    var defaultValue = false
    @State private var error: String?

    var body: some View {
        let nativePath = path.map(ComposeFieldPathComponent.key)
        let field = (try? ComposeDocument(text))?.nativeField(at: nativePath)
        if field?.kind == .boolean || field?.kind == .null || field?.value == "true" || field?.value == "false" {
            Toggle(
                title,
                isOn: Binding(
                    get: {
                        let current = (try? ComposeDocument(text))?.nativeField(at: nativePath)
                        return current?.kind == .null ? defaultValue : current?.value == "true"
                    },
                    set: { enabled in
                        guard !readOnly else { return }
                        do {
                            text = try ComposeDocument(text).settingNative(
                                String(enabled), kind: .boolean, at: nativePath)
                            error = nil
                        } catch { self.error = error.localizedDescription }
                    })
            ).disabled(readOnly)
        } else {
            LabeledContent(title, value: "Unavailable")
        }
        if let error { Text(error).foregroundStyle(.red) }
    }
}

private struct ComposeEnvironmentFileEntry: View {
    @Binding var text: String
    let readOnly: Bool
    let schemaPath: [ComposeFieldPathComponent]
    @State private var adding = false
    private var fields: Set<String> { Set(((try? ComposeDocument(text))?.nativeFields(at: []) ?? []).map(\.name)) }

    var body: some View {
        Form {
            if fields.contains("path") {
                ComposeScalarField(text: $text, path: ["path"], title: "Path", readOnly: readOnly)
            }
            if fields.contains("required") {
                ComposeBooleanField(
                    text: $text, path: ["required"], title: "Required", readOnly: readOnly, defaultValue: true)
            }
            if fields.contains("format") {
                ComposeScalarField(text: $text, path: ["format"], title: "Format", readOnly: readOnly)
            }
            if fields.isEmpty {
                ContentUnavailableView("No environment file settings", systemImage: "doc.text")
            } else {
                NavigationLink("All file settings") {
                    ComposeNativeFieldsForm(
                        text: $text, path: [], title: "Environment file settings", readOnly: readOnly,
                        schemaPath: schemaPath)
                }
            }
        }.navigationTitle("Environment file")
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .toolbar {
                if !readOnly {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button("Add configuration", systemImage: "plus") { adding = true }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                    }
                }
            }
            .sheet(isPresented: $adding) { ComposeAddFieldsSheet(text: $text, path: [], schemaPath: schemaPath) }
    }
}
