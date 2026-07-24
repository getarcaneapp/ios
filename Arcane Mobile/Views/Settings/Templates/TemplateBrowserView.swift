import SwiftUI
import Arcane

struct TemplateBrowserView: View {
    /// True when pushed inside an existing NavigationStack (e.g. from the
    /// Projects page): skips the owned stack + Done button and offers a
    /// Settings button into registry management instead.
    var embedded: Bool = false

    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @State private var store = TemplateBrowserStore()

    var body: some View {
        @Bindable var store = store

        if embedded {
            content(searchText: $store.searchText, source: $store.source)
        } else {
            NavigationStack {
                content(searchText: $store.searchText, source: $store.source)
            }
        }
    }

    private func content(
        searchText: Binding<String>,
        source: Binding<TemplateSourceSelection>
    ) -> some View {
        Group {
            if !canListTemplates {
                ContentUnavailableView(
                    "Templates Access Required",
                    systemImage: "lock.fill",
                    description: Text("Your role cannot list templates.")
                )
            } else if store.isLoading && store.templates.isEmpty {
                ProgressView("Loading templates…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage = store.errorMessage, store.templates.isEmpty {
                ContentUnavailableView {
                    Label("Couldn't Load Templates", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try Again") { Task { await store.reload() } }
                }
            } else {
                List {
                    Section {
                        Picker("Source", selection: source) {
                            ForEach(TemplateSourceSelection.allCases) { option in
                                Label(option.title, systemImage: option.icon).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityLabel("Template source")
                    }

                    if store.templates.isEmpty {
                        ContentUnavailableView {
                            Label(
                                store.queryKey == "|all" ? "No Templates" : "No Matching Templates",
                                systemImage: "doc.text.magnifyingglass"
                            )
                        }
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(groupedTemplates, id: \.name) { group in
                            Section(group.name) {
                                ForEach(group.templates) { template in
                                    if canReadTemplates {
                                        NavigationLink {
                                            TemplatePreviewView(template: template)
                                        } label: {
                                            TemplateRow(template: template)
                                        }
                                    } else {
                                        TemplateRow(template: template)
                                    }
                                }
                            }
                        }
                    }

                    if let errorMessage = store.errorMessage, !store.templates.isEmpty {
                        Section {
                            Label(errorMessage, systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }

                    if store.hasMore {
                        Button {
                            Task { await store.loadMore() }
                        } label: {
                            HStack {
                                Spacer()
                                if store.isLoadingMore {
                                    ProgressView()
                                } else {
                                    Label("Show More", systemImage: "arrow.down.circle")
                                        .font(.subheadline.weight(.semibold))
                                }
                                Spacer()
                            }
                            .padding(.vertical, 4)
                        }
                        .disabled(store.isLoadingMore)
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Templates")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search templates"
        )
        .toolbar {
            if !embedded {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            if embedded && canManageRegistries {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink {
                        TemplateRegistriesView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Manage Template Registries")
                }
            }
        }
        .task(id: queryTaskKey) {
            guard canListTemplates else { return }
            store.configure(client: manager.client)
            do {
                try await Task.sleep(for: .milliseconds(350))
                await store.reload(clearExisting: true)
            } catch {
                return
            }
        }
        .refreshable {
            guard canListTemplates else { return }
            await store.reload()
        }
    }

    private var clientIdentity: ObjectIdentifier? {
        manager.client.map { ObjectIdentifier($0.transport) }
    }

    private var queryTaskKey: String {
        "\(clientIdentity?.hashValue ?? 0)|\(store.queryKey)"
    }

    private var groupedTemplates: [(name: String, templates: [Template])] {
        let groups = Dictionary(grouping: store.templates) { template in
            template.registry?.name ?? (template.isRemote ? "Remote" : "Local")
        }
        return groups.keys.sorted().map { key in
            (name: key, templates: groups[key] ?? [])
        }
    }

    private var canManageRegistries: Bool {
        canListTemplates
            && manager.permissions.hasAny(
                [Permission.Templates.create, Permission.Templates.update, Permission.Templates.delete],
                in: nil
            )
    }

    private var canListTemplates: Bool {
        manager.permissions.has(Permission.Templates.list, in: nil)
    }

    private var canReadTemplates: Bool {
        manager.permissions.has(Permission.Templates.read, in: nil)
    }
}

struct TemplateRow: View {
    let template: Template

    var body: some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: template.metadata?.iconUrl, size: 36) {
                Image(systemName: template.isRemote ? "cloud.fill" : "doc.text.fill")
                    .font(.title3)
                    .foregroundStyle(template.isRemote ? .blue : .indigo)
                    .frame(width: 36, height: 36)
                    .glassEffectCompat(in: .circle)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(template.name)
                    .font(.headline)
                Text(template.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Label(template.isRemote ? "Remote" : "Local", systemImage: template.isRemote ? "cloud" : "internaldrive")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(template.isRemote ? .blue : .indigo)
                    if let version = template.metadata?.version, !version.isEmpty {
                        Text(version)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    if let tags = template.metadata?.tags, !tags.isEmpty {
                        Text("\(tags.count) tag\(tags.count == 1 ? "" : "s")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
