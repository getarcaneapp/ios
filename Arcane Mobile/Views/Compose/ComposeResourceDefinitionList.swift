import SwiftUI

/// Project resource definitions are distinct from a service's network attachments.
struct ComposeResourceDefinitionList: View {
    @Binding var text: String
    let kind: String
    let readOnly: Bool
    @State private var adding = false
    @State private var name = ""
    @State private var error: String?
    @FocusState private var nameFocused: Bool
    private var document: ComposeDocument? { try? ComposeDocument(text) }
    private var resourceNames: [String] { document?.nativeFields(at: [.key(kind)]).map(\.name) ?? [] }
    private var title: String { kind == "networks" ? "Networks" : "Named volumes" }

    var body: some View {
        List {
            ForEach(resourceNames, id: \.self) { key in
                NavigationLink {
                    ComposeResourceDefinitionForm(text: $text, kind: kind, name: key, readOnly: readOnly)
                } label: {
                    Label(key, systemImage: kind == "networks" ? "network" : "externaldrive")
                }
            }.onDelete(perform: remove).deleteDisabled(readOnly)
            if resourceNames.isEmpty {
                ContentUnavailableView(
                    "No \(title.lowercased())", systemImage: kind == "networks" ? "network" : "externaldrive")
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle(title)
        .toolbar {
            if !readOnly {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add", systemImage: "plus") {
                        name = ""
                        error = nil
                        adding = true
                    }
                }
            }
        }
        .sheet(isPresented: $adding) {
            NavigationStack {
                Form {
                    TextField("Name", text: $name).focused($nameFocused)
                    if let error { Text(error).foregroundStyle(.red) }
                }
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .navigationTitle(kind == "networks" ? "Add network" : "Add volume")
                .onAppear { nameFocused = true }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { adding = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add") { add() }
                            .disabled(name.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) == nil)
                    }
                }
            }
        }
    }

    private func add() {
        guard !readOnly else { return }
        do {
            let document = try ComposeDocument(text)
            guard !document.nativeFields(at: [.key(kind)]).contains(where: { $0.name == name }) else {
                throw ComposeFormError.duplicate
            }
            text = try document.addingNative("", kind: .mapping, key: name, at: [.key(kind)])
            error = nil
            adding = false
        } catch { self.error = error.localizedDescription }
    }

    private func remove(_ indices: IndexSet) {
        guard !readOnly else { return }
        do {
            let names = try ComposeDocument(text).nativeFields(at: [.key(kind)]).map(\.name)
            var source = text
            for index in indices.reversed() {
                source = try ComposeDocument(source).removingNative(at: [.key(kind), .key(names[index])])
            }
            text = source
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

struct ComposeResourceDefinitionForm: View {
    @Binding var text: String
    let kind: String
    let name: String
    let readOnly: Bool
    @State private var adding = false
    private var fields: Set<String> {
        Set(((try? ComposeDocument(text))?.nativeFields(at: path.map(ComposeFieldPathComponent.key)) ?? []).map(\.name))
    }
    private var path: [String] { [kind, name] }

    var body: some View {
        Form {
            if !fields.isDisjoint(with: ["name", "external", "driver"]) {
                Section("Resource") {
                    if fields.contains("name") {
                        ComposeScalarField(
                            text: $text, path: path + ["name"], title: "Docker resource name", readOnly: readOnly)
                    }
                    if fields.contains("external") {
                        ComposeBooleanField(
                            text: $text, path: path + ["external"], title: "External resource", readOnly: readOnly)
                    }
                    if fields.contains("driver") {
                        ComposeScalarField(text: $text, path: path + ["driver"], title: "Driver", readOnly: readOnly)
                    }
                }
            }
            if kind == "networks",
                !fields.isDisjoint(with: ["internal", "attachable", "enable_ipv4", "enable_ipv6", "ipam"])
            {
                Section("Network") {
                    if fields.contains("internal") {
                        ComposeBooleanField(
                            text: $text, path: path + ["internal"], title: "Internal", readOnly: readOnly)
                    }
                    if fields.contains("attachable") {
                        ComposeBooleanField(
                            text: $text, path: path + ["attachable"], title: "Attachable", readOnly: readOnly)
                    }
                    if fields.contains("enable_ipv4") {
                        ComposeBooleanField(
                            text: $text, path: path + ["enable_ipv4"], title: "IPv4", readOnly: readOnly,
                            defaultValue: true)
                    }
                    if fields.contains("enable_ipv6") {
                        ComposeBooleanField(
                            text: $text, path: path + ["enable_ipv6"], title: "IPv6", readOnly: readOnly)
                    }
                    if fields.contains("ipam") {
                        NavigationLink("IP address management") {
                            ComposeNativeFieldsForm(
                                text: $text, path: path + ["ipam"], title: "IP address management", readOnly: readOnly)
                        }
                    }
                }
            }
            if !fields.isDisjoint(with: ["driver_opts", "labels"]) {
                Section("Options") {
                    if fields.contains("driver_opts") {
                        NavigationLink("Driver options") {
                            ComposeNativeFieldsForm(
                                text: $text, path: path + ["driver_opts"], title: "Driver options", readOnly: readOnly)
                        }
                    }
                    if fields.contains("labels") {
                        NavigationLink("Labels") {
                            ComposeNativeFieldsForm(
                                text: $text, path: path + ["labels"], title: "Labels", readOnly: readOnly)
                        }
                    }
                }
            }
            if fields.isEmpty {
                ContentUnavailableView(
                    "No resource settings", systemImage: kind == "networks" ? "network" : "externaldrive")
            } else {
                NavigationLink("All resource settings") {
                    ComposeNativeFieldsForm(text: $text, path: path, title: "Resource settings", readOnly: readOnly)
                }
            }
        }
        .navigationTitle(name)
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
