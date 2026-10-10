import SwiftUI

/// Uses the Compose specification to offer fields without exposing YAML syntax.
struct ComposeAddFieldsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var text: String
    let fieldPath: [ComposeFieldPathComponent]
    let schemaPath: [ComposeFieldPathComponent]
    let excluding: Set<String>
    private let includesProjectSettings: Bool
    @State private var serviceSelection: String
    @State private var newServiceName = ""
    @State private var selectionIsProject = false
    @State private var search = ""
    @State private var draft: ComposeSettingDraft?
    @State private var needsName = false
    @State private var error: String?

    init(
        text: Binding<String>, path: [String], excluding: Set<String> = [],
        schemaPath: [ComposeFieldPathComponent]? = nil, includesProjectSettings: Bool = false,
        preferredService: String? = nil
    ) {
        _text = text
        fieldPath = path.map(ComposeFieldPathComponent.key)
        self.includesProjectSettings = includesProjectSettings
        let services = (try? ComposeDocument(text.wrappedValue))?.services ?? []
        _serviceSelection = State(
            initialValue: preferredService.flatMap { services.contains($0) ? $0 : nil } ?? services.first ?? "")
        self.excluding = excluding
        self.schemaPath = schemaPath ?? fieldPath
    }

    init(
        text: Binding<String>, fieldPath: [ComposeFieldPathComponent], excluding: Set<String> = [],
        schemaPath: [ComposeFieldPathComponent]? = nil
    ) {
        _text = text
        self.fieldPath = fieldPath
        includesProjectSettings = false
        _serviceSelection = State(initialValue: "")
        self.excluding = excluding
        self.schemaPath = schemaPath ?? fieldPath
    }

    private var services: [String] { (try? ComposeDocument(text))?.services ?? [] }
    private var serviceName: String {
        serviceSelection.isEmpty ? newServiceName.trimmingCharacters(in: .whitespacesAndNewlines) : serviceSelection
    }
    private var servicePath: [ComposeFieldPathComponent] {
        [.key("services"), .key(serviceName.isEmpty ? "new-service" : serviceName)]
    }
    private var destinationPath: [ComposeFieldPathComponent] {
        includesProjectSettings ? (selectionIsProject ? [] : servicePath) : fieldPath
    }
    private var isList: Bool {
        !includesProjectSettings && (try? ComposeDocument(text))?.nativeField(at: fieldPath).kind == .sequence
    }
    private var available: [ComposeSchemaField] {
        suggestions(
            at: includesProjectSettings ? servicePath : fieldPath,
            schemaPath: includesProjectSettings ? servicePath : schemaPath,
            excluding: excluding)
    }
    private var projectFields: [ComposeSchemaField] { suggestions(at: [], schemaPath: [], excluding: ["services"]) }

    private func suggestions(
        at path: [ComposeFieldPathComponent], schemaPath: [ComposeFieldPathComponent], excluding: Set<String>
    ) -> [ComposeSchemaField] {
        let existing = Set((try? ComposeDocument(text))?.nativeFields(at: path).map(\.name) ?? [])
        return ComposeSchema.fields(at: schemaPath).filter {
            !existing.contains($0.name) && !excluding.contains($0.name)
                && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
                    || $0.description.localizedCaseInsensitiveContains(search))
        }
    }
    var body: some View {
        Group {
            if isList {
                if let draft {
                    ComposeSettingEditor(draft: draft, needsName: false, save: add)
                }
            } else {
                NavigationStack {
                    List {
                        if includesProjectSettings {
                            Section {
                                if !services.isEmpty {
                                    Picker("Service", selection: $serviceSelection) {
                                        ForEach(services, id: \.self) { Text($0).tag($0) }
                                        Text("New service").tag("")
                                    }
                                }
                                if serviceSelection.isEmpty {
                                    TextField("Service name", text: $newServiceName)
                                }
                                if let error { Text(error).foregroundStyle(.red) }
                            } footer: {
                                if serviceSelection.isEmpty {
                                    Text("Enter a name, then choose a setting below to create the service.")
                                }
                            }
                            Section("Service settings") {
                                ForEach(available) { field in fieldButton(field) }
                                customFieldButton("Custom service field")
                            }
                            Section("Project settings") {
                                ForEach(projectFields) { field in fieldButton(field, project: true) }
                                customFieldButton("Custom project field", project: true)
                            }
                        } else {
                            ForEach(available) { field in fieldButton(field) }
                            customFieldButton("Custom field")
                        }
                    }.searchable(text: $search, prompt: "Find a Compose setting")
                        .navigationTitle("Add configuration")
                        .navigationBarTitleDisplayMode(.inline)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") { dismiss() }
                            }
                        }
                }
            }
        }
        .sheet(item: Binding(get: { isList ? nil : draft }, set: { draft = $0 })) { draft in
            if !isList { ComposeSettingEditor(draft: draft, needsName: needsName, save: add) }
        }
        .onAppear {
            if isList && draft == nil { select(ComposeSchema.value(at: schemaPath + [.index(0)])) }
        }
    }

    private func fieldButton(_ field: ComposeSchemaField, project: Bool = false) -> some View {
        Button {
            select(field, project: project)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(ComposeDisplayText.title(field.name)).foregroundStyle(Color.primary)
                if !field.description.isEmpty {
                    Text(field.description).font(.caption).foregroundStyle(Color.secondary).lineLimit(2)
                }
            }.padding(.vertical, 3)
        }
    }

    private func customFieldButton(_ title: String, project: Bool = false) -> some View {
        Button(title, systemImage: "plus") { select(nil, project: project) }
    }

    private func select(_ field: ComposeSchemaField?, project: Bool = false) {
        if includesProjectSettings, !project, serviceSelection.isEmpty {
            guard !serviceName.isEmpty else {
                error = "Enter a service name above."
                return
            }
            guard !services.contains(serviceName) else {
                error = "A service with this name already exists."
                return
            }
        }
        selectionIsProject = project
        needsName = field == nil && !isList
        let base = includesProjectSettings ? (project ? [] : servicePath) : schemaPath
        let itemIndex = (try? ComposeDocument(text))?.nativeFields(at: fieldPath).count ?? 0
        let path = base + (isList ? [.index(itemIndex)] : [.key(field?.name ?? "custom-setting")])
        var pending = ComposeSettingDraft(name: isList ? "Item" : (field?.name ?? ""), schemaPath: path, included: true)
        pending.prepareFields()
        error = nil
        draft = pending
    }

    private func add(_ pending: ComposeSettingDraft) -> String? {
        do {
            guard !excluding.contains(pending.name) else {
                throw ComposeFormError.invalid("This setting is managed outside this editor.")
            }
            guard !(includesProjectSettings && selectionIsProject && pending.name == "services") else {
                throw ComposeFormError.invalid("Use the service settings above to add a service.")
            }
            let newService =
                includesProjectSettings && !selectionIsProject && serviceSelection.isEmpty ? serviceName : nil
            let result = try pending.adding(to: text, at: destinationPath, newService: newService, listItem: isList)
            text = result
            if let newService { serviceSelection = newService }
            return nil
        } catch { return error.localizedDescription }
    }
}
