import SwiftUI

struct EnvPreviewEditor: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var text: String
    var readOnly = false
    var menuActions: AnyView? = nil
    @State private var raw = false
    @State private var revealed = Set<String>()
    @State private var adding = false
    @State private var error: String?
    private var document: EnvDocument { EnvDocument(text) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollableTabBar(
                selection: $raw,
                options: [
                    ScrollableTabOption(false, title: "Editor", systemImage: "slider.horizontal.3"),
                    ScrollableTabOption(true, title: "Text", systemImage: "chevron.left.forwardslash.chevron.right"),
                ],
                accessibilityLabel: "Environment editor mode"
            )
            if raw {
                CodeEditorView(text: $text, language: .env, readOnly: readOnly)
            } else {
                Form {
                    Section {
                        Text("Preview").font(.caption).foregroundStyle(.secondary)
                    }.listRowBackground(Color.clear)
                    ForEach(document.entries) { entry in
                        Section(entry.name) {
                            let layout =
                                dynamicTypeSize.isAccessibilitySize
                                ? AnyLayout(VStackLayout(alignment: .leading)) : AnyLayout(HStackLayout())
                            layout {
                                if revealed.contains(entry.name) {
                                    TextField("Value", text: binding(entry)).accessibilityLabel(entry.name)
                                } else {
                                    SecureField("Value", text: binding(entry)).accessibilityLabel(entry.name)
                                }
                                Button(revealed.contains(entry.name) ? "Hide" : "Reveal") {
                                    if !revealed.insert(entry.name).inserted { revealed.remove(entry.name) }
                                }.accessibilityLabel(
                                    "\(revealed.contains(entry.name) ? "Hide" : "Reveal") \(entry.name)")
                            }.privacySensitive().disabled(readOnly)
                        }
                        .contextMenu {
                            if !readOnly {
                                Button("Delete", role: .destructive) { text = document.removing(entry) }
                            }
                        }
                    }.onDelete { indices in
                        guard !readOnly else { return }
                        let entries = document.entries
                        for index in indices.reversed() { text = EnvDocument(text).removing(entries[index]) }
                    }.deleteDisabled(readOnly)
                    if document.entries.isEmpty {
                        ContentUnavailableView(
                            "No environment variables", systemImage: "list.bullet",
                            description: Text("Use Add to create a variable."))
                    }
                    if document.unsupportedLines > 0 {
                        Section {
                            Text("Unsupported entries: " + String(document.unsupportedLines))
                            Button("Open text editor") { raw = true }
                        }
                    }
                    if let error { Text(error).foregroundStyle(.red) }
                }.textInputAutocapitalization(.never).autocorrectionDisabled()
            }
        }
        .toolbar {
            if menuActions != nil || (!readOnly && !raw) {
                AppToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if !readOnly && !raw { Button("Add variable", systemImage: "plus") { adding = true } }
                        if let menuActions { menuActions }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("Editor actions")
                }
            }
        }
        .sheet(isPresented: $adding) {
            ComposeNameSheet(title: "Add variable", placeholder: "Variable name") { name in
                do {
                    text = try document.adding(name)
                    error = nil
                    return nil
                } catch { return error.localizedDescription }
            }
        }
    }

    private func binding(_ entry: EnvEntry) -> Binding<String> {
        Binding(
            get: { document.entries.first { $0.name == entry.name }?.value ?? entry.value },
            set: { value in
                do {
                    guard let current = document.entries.first(where: { $0.name == entry.name }) else {
                        throw ComposeFormError.changed
                    }
                    text = try document.setting(value, entry: current)
                    error = nil
                } catch { self.error = error.localizedDescription }
            })
    }
}
