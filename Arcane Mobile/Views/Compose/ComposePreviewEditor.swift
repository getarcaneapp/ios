import SwiftUI

/// A view over the original source, never a second serialized copy of the document.
struct ComposePreviewEditor: View {
    @Binding var text: String
    var readOnly = false
    var menuActions: AnyView? = nil
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var yaml = false
    @State private var selectedService: String?
    @State private var addingService = false
    @State private var addingConfiguration = false
    @State private var error: String?

    private var document: ComposeDocument? { try? ComposeDocument(text) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollableTabBar(
                selection: $yaml,
                options: [
                    ScrollableTabOption(false, title: "Editor", systemImage: "slider.horizontal.3"),
                    ScrollableTabOption(true, title: "YAML", systemImage: "chevron.left.forwardslash.chevron.right")
                ],
                accessibilityLabel: "Compose editor mode"
            )
            if yaml {
                CodeEditorView(text: $text, language: .yaml, readOnly: readOnly)
            } else if let document {
                if sizeClass == .regular {
                    NavigationSplitView {
                        serviceList(document)
                    } detail: {
                        if let selectedService, document.services.contains(selectedService) {
                            ComposeServiceForm(text: $text, service: selectedService, readOnly: readOnly, menuActions: menuActions)
                        } else {
                            ContentUnavailableView("Select a service", systemImage: "square.stack.3d.up")
                        }
                    }
                } else {
                    serviceList(document)
                }
            } else {
                ContentUnavailableView {
                    Label("Open YAML to continue", systemImage: "doc.text")
                } description: {
                    Text(parseError)
                } actions: {
                    Button("Edit YAML") { yaml = true }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).padding() }
        }
        .toolbar {
            if yaml, let menuActions {
                AppToolbarItem(placement: .topBarTrailing) {
                    Menu { menuActions } label: { Image(systemName: "ellipsis") }
                }
            }
        }
    }

    private var parseError: String {
        do { _ = try ComposeDocument(text); return "This document requires YAML editing." }
        catch { return error.localizedDescription }
    }

    private func serviceList(_ document: ComposeDocument) -> some View {
        List {
            Section {
                ForEach(document.services, id: \.self) { service in
                    Group {
                        if sizeClass == .regular {
                            Button { selectedService = service } label: { serviceRow(service, document: document) }
                        } else {
                            NavigationLink {
                                ComposeServiceForm(text: $text, service: service, readOnly: readOnly, menuActions: menuActions)
                            } label: {
                                serviceRow(service, document: document)
                            }
                        }
                    }
                    .contextMenu {
                        if !readOnly {
                            Button("Delete", role: .destructive) {
                                mutate { try ComposeDocument(text).removingNative(at: [.key("services"), .key(service)]) }
                            }
                        }
                    }
                }.onDelete { indices in
                    guard !readOnly else { return }
                    mutate {
                        var source = text
                        for index in indices.reversed() {
                            source = try ComposeDocument(source).removingNative(at: [.key("services"), .key(document.services[index])])
                        }
                        return source
                    }
                }.deleteDisabled(readOnly)
                if document.services.isEmpty {
                    ContentUnavailableView("No services", systemImage: "square.stack.3d.up", description: Text("Add a service to configure its container."))
                }
            } header: {
                HStack {
                    Text("Services")
                    Spacer()
                    Text("Preview").font(.caption2)
                }
            }
            let rootFields = Set(document.nativeFields(at: []).map(\.name))
            if !rootFields.isDisjoint(with: ["volumes", "networks"]) {
                Section("Project resources") {
                    if rootFields.contains("volumes") {
                        DynamicNavigationRow(title: "Named volumes", subtitle: resourceSummary("volumes", document: document), systemImage: "externaldrive.fill") {
                            ComposeResourceDefinitionList(text: $text, kind: "volumes", readOnly: readOnly)
                        }
                    }
                    if rootFields.contains("networks") {
                        DynamicNavigationRow(title: "Networks", subtitle: resourceSummary("networks", document: document), systemImage: "network") {
                            ComposeResourceDefinitionList(text: $text, kind: "networks", readOnly: readOnly)
                        }
                    }
                }
            }
            if rootFields.contains("x-arcane") {
                Section {
                    DynamicNavigationRow(title: "Arcane metadata", subtitle: "Icons, visibility, links and updates", systemImage: "square.stack.3d.up.fill") {
                        ComposeNativeFieldsForm(text: $text, path: ["x-arcane"], title: "Arcane metadata", readOnly: readOnly)
                    }
                }
            }
            if !rootFields.subtracting(["services", "volumes", "networks", "build", "deploy", "x-arcane"]).isEmpty {
                Section {
                    DynamicNavigationRow(title: "Project settings", subtitle: document.nativeFields(at: []).filter { !["services", "volumes", "networks", "build", "deploy", "x-arcane"].contains($0.name) }.map(\.name).joined(separator: ", "), systemImage: "slider.horizontal.3") {
                        ComposeNativeFieldsForm(text: $text, path: [], title: "Project settings", readOnly: readOnly, excluding: ["services", "volumes", "networks", "build", "deploy", "x-arcane"])
                    }
                }
            }
        }
        .textInputAutocapitalization(.never).autocorrectionDisabled()
        .toolbar {
            if menuActions != nil || (!readOnly && !yaml) {
                AppToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if !readOnly && !yaml {
                            Button("Add service", systemImage: "plus") { addingService = true }
                            Button("Add configuration", systemImage: "slider.horizontal.3") { addingConfiguration = true }
                        }
                        if let menuActions { menuActions }
                    } label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel("Editor actions")
                }
            }
        }
        .sheet(isPresented: $addingConfiguration) {
            ComposeAddFieldsSheet(text: $text, path: [], excluding: ["services", "build", "deploy"])
        }
        .sheet(isPresented: $addingService) {
            ComposeNameSheet(title: "Add service", placeholder: "Service name") { name in
                do {
                    let current = try ComposeDocument(text)
                    guard !current.services.contains(name) else { throw ComposeFormError.duplicate }
                    let servicePath: [ComposeFieldPathComponent] = [.key("services"), .key(name)]
                    let added = try current.addingNative("", kind: .mapping, key: name, at: [.key("services")])
                    text = try ComposeDocument(added).addingNative("", kind: .string, key: "image", at: servicePath)
                    selectedService = name
                    return nil
                } catch { return error.localizedDescription }
            }
        }
    }

    private func serviceRow(_ service: String, document: ComposeDocument) -> some View {
        let field = document.nativeField(at: [.key("services"), .key(service), .key("image")])
        return HStack(spacing: 12) {
            Image(systemName: "cube.box.fill")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 36, height: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(service).font(.headline).foregroundStyle(.primary)
                if field.kind == .string, !field.value.isEmpty {
                    Text(field.value).font(.subheadline).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle)
                }
            }
            .padding(.vertical, 6)
        }
        .accessibilityElement(children: .combine)
    }

    private func resourceSummary(_ kind: String, document: ComposeDocument) -> String {
        let names = document.nativeFields(at: [.key(kind)]).map(\.name)
        return names.isEmpty ? "No entries" : names.joined(separator: ", ")
    }

    private func mutate(_ change: () throws -> String) {
        do { text = try change(); error = nil } catch { self.error = error.localizedDescription }
    }
}

struct ComposeServiceForm: View {
    @Binding var text: String
    let service: String
    let readOnly: Bool
    var menuActions: AnyView? = nil
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var error: String?
    @State private var addingFields = false
    @ScaledMetric(relativeTo: .title3) private var tileIconHeight = 28
    private var document: ComposeDocument? { try? ComposeDocument(text) }
    private var path: [String] { ["services", service] }
    private var existingFields: Set<String> {
        Set((document?.nativeFields(at: path.map(ComposeFieldPathComponent.key)) ?? []).map(\.name))
    }
    private let primaryFields: Set<String> = ["image", "pull_policy", "ports", "volumes", "networks", "environment", "env_file", "labels", "healthcheck", "restart", "command", "entrypoint", "container_name", "hostname", "domainname", "extra_hosts", "dns", "dns_opt", "dns_search", "build", "deploy"]
    private var additionalFields: [String] { existingFields.subtracting(primaryFields).subtracting(["x-arcane"]).sorted() }
    private func has(_ key: String) -> Bool { existingFields.contains(key) }
    private func hasAny(_ keys: Set<String>) -> Bool { !existingFields.isDisjoint(with: keys) }
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), alignment: .topLeading), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if has("image") {
                NavigationLink {
                    Form {
                        Section("Image") { scalar("Image", key: "image") }
                        if has("pull_policy") { Section { policy("Pull policy", key: "pull_policy", values: ["always", "missing", "never", "daily", "weekly"]) } }
                        if let error { Text(error).foregroundStyle(.red) }
                    }.navigationTitle("Image settings")
                } label: {
                    let layout = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
                        : AnyLayout(HStackLayout(alignment: .top, spacing: 14))
                    layout {
                        Image(systemName: "shippingbox.fill").font(.title2).foregroundStyle(.tint)
                            .padding(12).background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: Radius.nested, style: .continuous))
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Container image").font(.subheadline).foregroundStyle(.secondary)
                            Text(value("image") ?? "Choose an image").font(.headline).multilineTextAlignment(.leading).textSelection(.enabled)
                            if has("pull_policy") { Text("Pull policy: " + (value("pull_policy") ?? "Default")).font(.caption).foregroundStyle(.secondary) }
                        }
                        if !dynamicTypeSize.isAccessibilitySize {
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                    }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                }.buttonStyle(PressableButtonStyle())
                }

                if hasAny(["ports", "volumes", "networks", "environment", "env_file", "labels"]) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Configuration").font(.headline)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        if has("ports") { tile("Ports", icon: "arrow.left.arrow.right", tint: .blue, summary: countSummary("ports", singular: "port", plural: "ports")) { collection("ports", title: "Ports", kind: .port) } }
                        if has("volumes") { tile("Mounts", icon: "externaldrive", tint: .orange, summary: countSummary("volumes", singular: "mount", plural: "mounts")) { collection("volumes", title: "Mounts", kind: .mount) } }
                        if has("networks") { tile("Networks", icon: "network", tint: .teal, summary: countSummary("networks", singular: "attachment", plural: "attachments")) { ComposeNetworkAttachmentsForm(text: $text, path: path + ["networks"], readOnly: readOnly) } }
                        if has("environment") { tile("Environment", icon: "key.horizontal", tint: .purple, summary: countSummary("environment", singular: "variable", plural: "variables")) { keyValues("environment", title: "Environment variables") } }
                        if has("env_file") { tile("Environment files", icon: "doc.text", tint: .indigo, summary: countSummary("env_file", singular: "file", plural: "files")) { strings("env_file", title: "Environment files") } }
                        if has("labels") { tile("Labels", icon: "tag", tint: .brown, summary: countSummary("labels", singular: "label", plural: "labels")) { keyValues("labels", title: "Labels") } }
                    }
                }
                }

                if has("healthcheck") {
                VStack(spacing: 0) {
                    route("Healthcheck", icon: "heart.text.clipboard", summary: healthcheckSummary) { ComposeHealthcheckForm(text: $text, path: path + ["healthcheck"], readOnly: readOnly) }
                }.background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Radius.standard, style: .continuous))
                }

                if hasAny(["restart", "command", "entrypoint", "container_name", "hostname", "domainname", "extra_hosts", "dns", "dns_opt", "dns_search"]) {
                VStack(spacing: 0) {
                    if hasAny(["restart", "command", "entrypoint"]) {
                    route("Runtime", icon: "terminal", summary: has("restart") ? "Restart: " + (value("restart") ?? "Default") : (has("command") ? "Custom command" : "Custom entrypoint")) {
                        Form {
                            if has("restart") { Section { policy("Restart policy", key: "restart", values: ["no", "always", "on-failure", "unless-stopped"]) } }
                            if let error { Text(error).foregroundStyle(.red) }
                            Section {
                                if has("command") { NavigationLink("Command") { strings("command", title: "Command") } }
                                if has("entrypoint") { NavigationLink("Entrypoint") { strings("entrypoint", title: "Entrypoint") } }
                            }
                        }.navigationTitle("Runtime")
                    }
                    }

                    if hasAny(["container_name", "hostname", "domainname"]) {
                    route("Identity", icon: "person.text.rectangle", summary: value("container_name") ?? value("hostname") ?? value("domainname") ?? "Configured") {
                        Form {
                            if has("container_name") { scalar("Container name", key: "container_name") }
                            if has("hostname") { scalar("Hostname", key: "hostname") }
                            if has("domainname") { scalar("Domain name", key: "domainname") }
                        }.navigationTitle("Identity")
                    }
                    }

                    if hasAny(["extra_hosts", "dns", "dns_opt", "dns_search"]) {
                    route("Name resolution", icon: "globe", summary: "DNS and host mappings") {
                        Form {
                            if has("extra_hosts") {
                            NavigationLink("Extra hosts") {
                                if document?.nativeField(at: (path + ["extra_hosts"]).map(ComposeFieldPathComponent.key)).kind == .sequence {
                                    strings("extra_hosts", title: "Extra hosts", allowsScalar: false)
                                } else {
                                    ComposeMappingForm(text: $text, path: path + ["extra_hosts"], title: "Extra hosts", resource: false, readOnly: readOnly, sensitive: false)
                                }
                            }
                            }
                            if has("dns") { NavigationLink("DNS servers") { strings("dns", title: "DNS servers") } }
                            if has("dns_opt") { NavigationLink("DNS options") { strings("dns_opt", title: "DNS options") } }
                            if has("dns_search") { NavigationLink("DNS search domains") { strings("dns_search", title: "DNS search domains") } }
                        }.navigationTitle("Name resolution")
                    }
                    }
                }.background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Radius.standard, style: .continuous))
                }

                if has("x-arcane") {
                    route("Arcane metadata", icon: "square.stack.3d.up.fill", summary: "Icons, visibility and updates") {
                        ComposeNativeFieldsForm(text: $text, path: path + ["x-arcane"], title: "Arcane metadata", readOnly: readOnly)
                    }
                }
                if !additionalFields.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Additional settings").font(.headline)
                        VStack(spacing: 0) {
                            ForEach(additionalFields, id: \.self) { key in
                                route(key.replacingOccurrences(of: "_", with: " ").capitalized, icon: "slider.horizontal.3", summary: "Configured") {
                                    ComposeNativeFieldsForm(text: $text, path: path + [key], title: key, readOnly: readOnly)
                                }
                            }
                        }.background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Radius.standard, style: .continuous))
                    }
                }
                if has("pull_policy"), !has("image") {
                    route("Pull policy", icon: "arrow.down.circle", summary: value("pull_policy") ?? "Default") {
                        Form { policy("Pull policy", key: "pull_policy", values: ["always", "missing", "never", "daily", "weekly"]) }.navigationTitle("Pull policy")
                    }
                }
                if !existingFields.subtracting(["build", "deploy"]).isEmpty {
                route("All service settings", icon: "slider.horizontal.3", summary: "Browse every configuration field") {
                    ComposeNativeFieldsForm(text: $text, path: path, title: "Service settings", readOnly: readOnly, excluding: ["build", "deploy"])
                }
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }.padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(service)
        .textInputAutocapitalization(.never).autocorrectionDisabled()
        .toolbar {
            if !readOnly || menuActions != nil {
                AppToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if !readOnly { Button("Add configuration", systemImage: "plus") { addingFields = true } }
                        if let menuActions { menuActions }
                    } label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel("Service actions")
                }
            }
        }
        .sheet(isPresented: $addingFields) {
            ComposeAddFieldsSheet(text: $text, path: path, excluding: ["build", "deploy"])
        }
    }

    private func value(_ key: String) -> String? { scalarValue(at: path + [key]) }

    private func scalarValue(at fieldPath: [String]) -> String? {
        guard let field = document?.nativeField(at: fieldPath.map(ComposeFieldPathComponent.key)),
              [.string, .number, .boolean].contains(field.kind) else { return nil }
        return field.value
    }

    private func countSummary(_ key: String, singular: String, plural: String) -> String {
        guard let document else { return "Not configured" }
        let fieldPath = (path + [key]).map(ComposeFieldPathComponent.key)
        let field = document.nativeField(at: fieldPath)
        if field.kind == .mapping || field.kind == .sequence {
            let count = document.nativeFields(at: fieldPath).count
            return String(count) + " " + (count == 1 ? singular : plural)
        }
        if field.kind == .null { return "Not configured" }
        if field.kind == .unsupported { return "Configured" }
        return "1 " + singular
    }

    private var healthcheckSummary: String {
        let health = path + ["healthcheck"]
        guard has("healthcheck") else { return "Not configured" }
        if scalarValue(at: health + ["disable"])?.lowercased() == "true" { return "Disabled" }
        if let interval = scalarValue(at: health + ["interval"]) { return "Every " + interval }
        return "Configured"
    }

    private func tile<Destination: View>(_ title: String, icon: String, tint: Color, summary: String, @ViewBuilder destination: () -> Destination) -> some View {
        NavigationLink(destination: destination) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: icon).font(.title3).foregroundStyle(tint).frame(height: tileIconHeight)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        }.buttonStyle(PressableButtonStyle())
    }

    private func route<Destination: View>(_ title: String, icon: String, summary: String, @ViewBuilder destination: () -> Destination) -> some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.body).foregroundStyle(.secondary).frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.subheadline.weight(.medium))
                    Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func policy(_ title: String, key: String, values: [String]) -> some View {
        let current = value(key) ?? ""
        return Picker(title, selection: Binding(get: { value(key) ?? "" }, set: { selected in
            do {
                let currentDocument = try ComposeDocument(text)
                if selected.isEmpty {
                    let parent = path.map(ComposeFieldPathComponent.key)
                    if currentDocument.nativeFields(at: parent).contains(where: { $0.name == key }) {
                        text = try currentDocument.removingNative(at: parent + [.key(key)])
                    }
                } else {
                    text = try currentDocument.settingNative(selected, kind: .string, at: (path + [key]).map(ComposeFieldPathComponent.key))
                }
                error = nil
            } catch { self.error = error.localizedDescription }
        })) {
            Text("Default").tag("")
            ForEach(values, id: \.self) { value in Text(value).tag(value) }
            if !current.isEmpty, !values.contains(current) { Text("Custom: " + current).tag(current) }
        }.disabled(readOnly)
    }

    private func scalar(_ title: String, key: String) -> some View {
        ComposeScalarField(text: $text, path: path + [key], title: title, readOnly: readOnly)
    }
    private func strings(_ key: String, title: String, allowsScalar: Bool = true) -> some View {
        ComposeStringListForm(text: $text, path: path + [key], title: title, readOnly: readOnly, allowsScalar: allowsScalar, environmentFiles: key == "env_file")
    }
    private func collection(_ key: String, title: String, kind: ComposeEntryKind) -> some View {
        ComposeCollectionForm(text: $text, path: path + [key], title: title, kind: kind, readOnly: readOnly)
    }
    private func keyValues(_ key: String, title: String) -> some View {
        ComposeMappingForm(text: $text, path: path + [key], title: title, resource: false, readOnly: readOnly)
    }
}

private struct ComposeMappingForm: View {
    @Binding var text: String
    let path: [String]
    let title: String
    let resource: Bool
    let readOnly: Bool
    var sensitive = true
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var adding = false
    @State private var error: String?
    @State private var revealed = Set<String>()
    private var document: ComposeDocument? { try? ComposeDocument(text) }

    private var nativeFallback: Bool {
        guard let document else { return false }
        let typedPath = path.map(ComposeFieldPathComponent.key)
        let kind = document.nativeField(at: typedPath).kind
        guard kind == .mapping || kind == .sequence else { return false }
        return !document.isEditable(at: path) || document.rawValue(at: path) == nil ||
            document.nativeFields(at: typedPath).contains { $0.kind == .mapping || $0.kind == .sequence }
    }

    var body: some View {
        Group {
            if nativeFallback {
                ComposeNativeFieldsForm(text: $text, path: path, title: title, readOnly: readOnly)
            } else if !resource, document?.items(at: path) != nil {
                ComposeCollectionForm(text: $text, path: path, title: title, kind: .keyValue, readOnly: readOnly)
            } else {
                Form {
                    if let document, document.isEditable(at: path) {
                        ForEach(document.keys(at: path), id: \.self) { key in
                            Section(key) {
                                if resource {
                                    LabeledContent("Name", value: key)
                                } else if document.scalar(at: path + [key]) != nil || document.rawValue(at: path + [key]) == nil {
                                    let layout = dynamicTypeSize.isAccessibilitySize
                                        ? AnyLayout(VStackLayout(alignment: .leading)) : AnyLayout(HStackLayout())
                                    layout {
                                        if revealed.contains(key) || title == "Labels" || !sensitive {
                                            TextField("Value", text: binding(key)).accessibilityLabel(key)
                                        } else {
                                            SecureField("Value", text: binding(key)).accessibilityLabel(key)
                                        }
                                        if title != "Labels", sensitive {
                                            Button(revealed.contains(key) ? "Hide" : "Reveal") {
                                                if !revealed.insert(key).inserted { revealed.remove(key) }
                                            }
                                        }
                                    }.disabled(readOnly).privacySensitive()
                                } else {
                                    Text("Unsupported value").foregroundStyle(.secondary)
                                }
                            }
                            .contextMenu {
                                if !readOnly {
                                    Button("Delete", role: .destructive) { change { try $0.removing(at: path + [key]) } }
                                }
                            }
                        }.onDelete { indices in
                            guard !readOnly else { return }
                            let keys = document.keys(at: path)
                            change { current in
                                var source = text
                                for index in indices.reversed() {
                                    source = try ComposeDocument(source).removing(at: path + [keys[index]])
                                }
                                return source
                            }
                        }.deleteDisabled(readOnly)
                        if document.keys(at: path).isEmpty {
                            ContentUnavailableView("No " + title.lowercased(), systemImage: "list.bullet", description: Text("Use Add to create an entry."))
                        }
                    } else {
                        Text("Unsupported format")
                    }
                    if let error { Text(error).foregroundStyle(.red) }
                }.navigationTitle(title)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .toolbar {
                        if !readOnly {
                            AppToolbarItem(placement: .topBarTrailing) {
                                Button("Add", systemImage: "plus") { adding = true }
                            }
                        }
                    }
                    .sheet(isPresented: $adding) {
                        ComposeNameSheet(title: "Add entry", placeholder: "Name") { name in
                            change { current in
                                guard !current.keys(at: path).contains(name) else { throw ComposeFormError.duplicate }
                                return try current.setting("\"\"", at: path + [name])
                            }
                            return error
                        }
                    }
            }
        }
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { document?.scalar(at: path + [key]) ?? "" }, set: { value in
            change { try $0.setting(ComposeDocument.quoted(value), at: path + [key]) }
        })
    }
    private func change(_ action: (ComposeDocument) throws -> String) {
        do { text = try action(ComposeDocument(text)); error = nil } catch { self.error = error.localizedDescription }
    }
}

private struct ComposeCollectionForm: View {
    @Binding var text: String
    let path: [String]
    let title: String
    let kind: ComposeEntryKind
    let readOnly: Bool
    @State private var editing: ComposeEntrySelection?
    @State private var error: String?
    private var document: ComposeDocument? { try? ComposeDocument(text) }

    private var nativeFallback: Bool {
        guard let document else { return false }
        let kind = document.nativeField(at: path.map(ComposeFieldPathComponent.key)).kind
        return kind == .sequence && (!document.isEditable(at: path) || document.rawValue(at: path) == nil)
    }

    var body: some View {
        Group {
            if nativeFallback {
                ComposeNativeFieldsForm(text: $text, path: path, title: title, readOnly: readOnly)
            } else { legacyBody }
        }
    }

    private var legacyBody: some View {
        Form {
            if let document, document.isEditable(at: path),
               document.items(at: path) != nil || document.rawValue(at: path) == nil {
                let items = document.items(at: path) ?? []
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    Button {
                        editing = ComposeEntrySelection(index: index, raw: item)
                    } label: {
                        HStack {
                            Text(kind == .keyValue ? entryName(item) : item).lineLimit(2)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }
                    }.disabled(readOnly)
                    .contextMenu {
                        if !readOnly {
                            Button("Delete", role: .destructive) {
                                do { text = try ComposeDocument(text).removingItem(at: path, index: index); error = nil }
                                catch { self.error = error.localizedDescription }
                            }
                        }
                    }
                }.onDelete { indices in
                    guard !readOnly else { return }
                    do {
                        var source = text
                        for index in indices.reversed() { source = try ComposeDocument(source).removingItem(at: path, index: index) }
                        text = source; error = nil
                    } catch { self.error = error.localizedDescription }
                }.deleteDisabled(readOnly)
                if items.isEmpty {
                    ContentUnavailableView("No " + title.lowercased(), systemImage: "list.bullet", description: Text("Use Add to create an entry."))
                }
            } else if kind == .network {
                NavigationLink("Network attachments") {
                    ComposeNetworkAttachmentsForm(text: $text, path: path, readOnly: readOnly)
                }
            } else {
                Text("Unsupported format")
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle(title)
            .toolbar {
                if !readOnly {
                    AppToolbarItem(placement: .topBarTrailing) {
                        Button("Add", systemImage: "plus") { editing = ComposeEntrySelection(index: nil, raw: "") }
                    }
                }
            }
            .sheet(item: $editing) { selection in
                ComposeEntrySheet(kind: kind, original: selection.raw, schemaPath: path.map(ComposeFieldPathComponent.key) + [.index(selection.index ?? 0)]) { raw, externalResource in
                    do {
                        if selection.index != nil, raw == selection.raw, externalResource == nil { return nil }
                        var source = text
                        if let externalResource {
                            if kind == .mount, let mountType = try ComposeDocument(raw).scalar(at: ["type"]), mountType != "volume" {
                                throw ComposeFormError.invalid("This mount uses \(mountType). Change its type to volume in All settings before selecting an existing volume.")
                            }
                            let resourcePath = [kind == .mount ? "volumes" : "networks", externalResource]
                            let existing = try ComposeDocument(source)
                            if existing.rawValue(at: resourcePath) == nil {
                                source = try existing.setting("external: true", at: resourcePath)
                            } else if existing.scalar(at: resourcePath + ["external"]) != "true" {
                                throw ComposeFormError.invalid("This name already has a project resource definition. Configure it as external in Project resources before selecting the existing Docker resource.")
                            }
                        }
                        if externalResource == nil, kind == .mount || kind == .network,
                           let entry = try? ComposeEntryDraft(raw: raw, kind: kind) {
                            let name = entry.source
                            let named = kind == .network || (!name.isEmpty && !name.hasPrefix("/") && !name.hasPrefix(".") && !name.hasPrefix("~"))
                            if named {
                                let resourcePath = [kind == .mount ? "volumes" : "networks", name]
                                let existing = try ComposeDocument(source)
                                if !existing.keys(at: [resourcePath[0]]).contains(name) {
                                    source = try existing.setting("{}", at: resourcePath)
                                }
                            }
                        }
                        let current = try ComposeDocument(source)
                        if let index = selection.index {
                            guard let items = current.items(at: path), items.indices.contains(index), items[index] == selection.raw else { throw ComposeFormError.changed }
                            text = try current.settingItem(raw, at: path, index: index)
                        } else {
                            text = try current.appendingItem(raw, at: path)
                        }
                        error = nil
                        return nil
                    } catch { return error.localizedDescription }
                }
            }
    }
    private func entryName(_ raw: String) -> String {
        let value = (try? ComposeDocument("entry: " + raw).scalar(at: ["entry"])) ?? raw
        return String(value.split(separator: "=", maxSplits: 1).first ?? "")
    }
}

private struct ComposeEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    let kind: ComposeEntryKind
    let original: String
    let schemaPath: [ComposeFieldPathComponent]
    let save: (String, String?) -> String?
    @State private var draft = ComposeEntryDraft()
    @State private var error: String?
    @State private var supported = true
    @State private var reveal = false
    @FocusState private var focused: Bool
    @State private var showResources = false
    @State private var externalResource: String?
    @State private var nativeSource = ""
    @State private var showNativeSettings = false
    @State private var nativeWrapper = ""
    @State private var initialized = false


    var body: some View {
        NavigationStack {
            Form {
                if supported {
                    switch kind {
                    case .port:
                        entryField("Host address (optional)") { TextField("Host address", text: $draft.address).focused($focused) }
                        entryField("Host port (optional)") { TextField("Host port", text: $draft.source).keyboardType(.numbersAndPunctuation) }
                        entryField("Container port") { TextField("Container port", text: $draft.target).keyboardType(.numbersAndPunctuation) }
                        Picker("Protocol", selection: $draft.option) {
                            Text("TCP").tag("tcp"); Text("UDP").tag("udp"); Text("SCTP").tag("sctp")
                        }
                    case .mount:
                        entryField("Volume name or host path (optional)") { TextField("Volume name or host path", text: $draft.source).focused($focused) }
                        entryField("Container path") { TextField("Container path", text: $draft.target) }
                        Toggle("Read only", isOn: $draft.readOnly)
                        resourceButton
                    case .keyValue:
                        entryField("Name") { TextField("Name", text: $draft.source).focused($focused) }
                        entryField("Value") {
                            if reveal { TextField("Value", text: $draft.target).privacySensitive() }
                            else { SecureField("Value", text: $draft.target).privacySensitive() }
                        }
                        Toggle("Reveal value", isOn: $reveal)
                    case .network:
                        entryField("Network name") { TextField("Network name", text: $draft.source).focused($focused) }
                        resourceButton
                    }
                } else {
                    Text("Unsupported format")
                }
                if kind == .port || kind == .mount {
                    Button("All settings") {
                        do {
                            nativeSource = supported ? try draft.yaml(kind: kind) : nativeSource
                            nativeWrapper = "entry:\n" + nativeSource.split(separator: "\n", omittingEmptySubsequences: false).map { "  " + $0 }.joined(separator: "\n")
                            showNativeSettings = true
                        } catch { self.error = error.localizedDescription }
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .navigationTitle(original.isEmpty ? "Add entry" : "Edit entry")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        do {
                            let raw = supported ? try draft.yaml(kind: kind) : nativeSource
                            error = save(raw, supported && externalResource == draft.source ? externalResource : nil)
                            if error == nil { dismiss() }
                        } catch { self.error = error.localizedDescription }
                    }.disabled(!supported && nativeSource.isEmpty)
                }
            }
            .sheet(isPresented: $showNativeSettings, onDismiss: applyNativeSettings) {
                NavigationStack {
                    ComposeNativeFieldsForm(text: $nativeWrapper, path: ["entry"], title: "Entry settings", readOnly: false, schemaPath: schemaPath)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showNativeSettings = false }
                            }
                        }
                }
            }
            .sheet(isPresented: $showResources) {
                ComposeResourcePicker(kind: kind, selection: Binding(
                    get: { draft.source },
                    set: { draft.source = $0; externalResource = $0 }
                ))
            }
            .onAppear {
                guard !initialized else { return }
                initialized = true
                nativeSource = original
                do { draft = try ComposeEntryDraft(raw: original, kind: kind); focused = true }
                catch { supported = false }
            }
        }
    }

    private func entryField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    private func applyNativeSettings() {
        do {
            let document = try ComposeDocument(nativeWrapper)
            guard let raw = document.rawValue(at: ["entry"]) else {
                throw ComposeFormError.invalid("The entry cannot be empty.")
            }
            nativeSource = raw
            do {
                draft = try ComposeEntryDraft(raw: raw, kind: kind)
                supported = true
            } catch {
                supported = false
            }
            externalResource = nil
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private var resourceButton: some View {
        Group {
            Button("Choose existing resource") { showResources = true }
            if externalResource == draft.source {
                Text("This resource will be declared external in the Compose file.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

private func validName(_ value: String) -> Bool {
    !value.isEmpty && value.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil
}

struct ComposeNameSheet: View {
    let title: String
    let placeholder: String
    let save: (String) -> String?
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var name = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField(placeholder, text: $name).focused($focused)
                if let error { Text(error).foregroundStyle(.red) }
            }
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        error = save(name)
                        if error == nil { dismiss() }
                    }.disabled(!validName(name))
                }
            }
            .onAppear { focused = true }
        }
    }
}
