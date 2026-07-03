import SwiftUI
import Arcane

struct TemplateRegistriesView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @State private var registries: [TemplateRegistry] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showCreateSheet = false
    @State private var editingRegistry: TemplateRegistry?
    @State private var actionErrorMessage: String?
    @State private var pendingDeleteRegistry: TemplateRegistry?
    @State private var isAddingCommunity = false

    /// The official community registry the web UI also offers one-tap setup for.
    private static let communityRegistryURL = "https://registry.getarcane.app/registry.json"

    private var hasCommunityRegistry: Bool {
        registries.contains { $0.url.lowercased() == Self.communityRegistryURL.lowercased() }
    }

    var body: some View {
        Group {
            if manager.currentUser?.isAdmin != true {
                ContentUnavailableView("Admin Required", systemImage: "lock.fill", description: Text("Only administrators can manage template registries."))
            } else if isLoading && registries.isEmpty {
                ProgressView("Loading template registries...").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage, registries.isEmpty {
                ContentUnavailableView {
                    Label("Couldn't Load Template Registries", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try Again") { Task { await loadRegistries(refresh: true) } }
                }
            } else if registries.isEmpty {
                ContentUnavailableView {
                    Label("No Template Registries", systemImage: "doc.text")
                } description: {
                    Text("Add a registry to browse and deploy ready-made project templates.")
                } actions: {
                    Button {
                        Task { await addCommunityRegistry() }
                    } label: {
                        if isAddingCommunity {
                            ProgressView()
                        } else {
                            Text("Add Community Registry")
                        }
                    }
                    .disabled(isAddingCommunity)
                    Button("Add Custom Registry") { showCreateSheet = true }
                }
            } else {
                List {
                    ForEach(registries) { registry in
                        PressableTemplateRegistryRow(
                            registry: registry,
                            onEdit: { editingRegistry = registry },
                            onDelete: { pendingDeleteRegistry = registry }
                        )
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button {
                                pendingDeleteRegistry = registry
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .tint(.red)
                        }
                    }

                    // One-tap add for the official community registry when it
                    // isn't configured yet (mirrors the web's suggestion card).
                    if !hasCommunityRegistry {
                        Section {
                            Button {
                                Task { await addCommunityRegistry() }
                            } label: {
                                HStack {
                                    Label("Add Community Registry", systemImage: "person.2")
                                    Spacer()
                                    if isAddingCommunity { ProgressView() }
                                }
                            }
                            .disabled(isAddingCommunity)
                        } footer: {
                            Text("Official Arcane community templates (\(Self.communityRegistryURL)).")
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Template Registries")
        .deleteConfirmation(
            item: $pendingDeleteRegistry,
            title: { _ in "Delete Template Registry" },
            message: { _ in "This removes the template registry." },
            icon: "trash",
            confirmTitle: "Delete"
        ) { registry in
            Task { await deleteTemplateRegistry(registry) }
        }
        .toolbar {
            if manager.currentUser?.isAdmin == true {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showCreateSheet = true } label: { Image(systemName: "plus") }.accessibilityLabel("Add Template Registry")
                }
            }
        }
        .task {
            guard manager.currentUser?.isAdmin == true else { return }
            await loadRegistries()
        }
        .refreshable {
            guard manager.currentUser?.isAdmin == true else { return }
            await loadRegistries(refresh: true)
        }
        .sheet(isPresented: $showCreateSheet) {
            TemplateRegistryFormView(registry: nil) {
                if let cached = manager.cached {
                    await cached.invalidateGlobal(paths: ["templates/registries", "templates/registries/*", "templates/all"])
                }
                await loadRegistries(refresh: true)
            }
        }
        .sheet(item: $editingRegistry) { registry in
            TemplateRegistryFormView(registry: registry) {
                if let cached = manager.cached {
                    await cached.invalidateGlobal(paths: ["templates/registries", "templates/registries/*", "templates/all"])
                }
                await loadRegistries(refresh: true)
            }
        }
        .alert(
            "Couldn't Delete Registry",
            isPresented: Binding(
                get: { actionErrorMessage != nil },
                set: { if !$0 { actionErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { actionErrorMessage = nil }
        } message: {
            Text(actionErrorMessage ?? "")
        }
    }

    private func loadRegistries(refresh: Bool = false) async {
        guard manager.currentUser?.isAdmin == true, let cached = manager.cached else { return }
        if registries.isEmpty { isLoading = true }
        if refresh { errorMessage = nil }
        defer { isLoading = false }
        do {
            if let result: [TemplateRegistry] = try await cached.getListGlobal(
                "templates/registries", elementType: TemplateRegistry.self,
                policy: .templates, refresh: refresh,
                onFresh: { fresh in registries = fresh }
            ) {
                registries = result
            }
            errorMessage = nil
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func addCommunityRegistry() async {
        guard manager.currentUser?.isAdmin == true, let client = manager.client else { return }
        isAddingCommunity = true
        defer { isAddingCommunity = false }
        do {
            let body = CreateTemplateRegistryRequest(
                name: "Arcane Community Templates",
                url: Self.communityRegistryURL,
                description: "Official Arcane community template registry",
                enabled: true
            )
            let _: TemplateRegistry = try await client.rest.post("templates/registries", body: body)
            if let cached = manager.cached {
                await cached.invalidateGlobal(paths: ["templates/registries", "templates/registries/*", "templates/all"])
            }
            await loadRegistries(refresh: true)
            showToast(.success("Community registry added"))
        } catch {
            actionErrorMessage = friendlyErrorMessage(error)
        }
    }

    private func deleteTemplateRegistry(_ registry: TemplateRegistry) async {
        guard manager.currentUser?.isAdmin == true, let client = manager.client else { return }
        do {
            let _: DataResponse<String> = try await client.rest.delete("templates/registries/\(registry.id)")
            withAnimation {
                registries.removeAll { $0.id == registry.id }
            }
            if let cached = manager.cached {
                await cached.invalidateGlobal(paths: ["templates/registries", "templates/registries/*", "templates/all"])
            }
        } catch {
            actionErrorMessage = friendlyErrorMessage(error)
        }
    }
}

struct TemplateRegistryRow: View {
    let registry: TemplateRegistry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text.fill")
                .font(.title3).foregroundStyle(.indigo)
                .frame(width: 36, height: 36)
                .glassEffectCompat(in: .circle)
            VStack(alignment: .leading, spacing: 3) {
                Text(registry.name).font(.headline)
                Text(registry.url).font(.caption).foregroundStyle(.secondary)
                if let error = registry.lastFetchError, !error.isEmpty {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if !registry.enabled {
                Text("Disabled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct PressableTemplateRegistryRow: View {
    let registry: TemplateRegistry
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onEdit) {
            TemplateRegistryRow(registry: registry)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(action: onEdit) {
                Label("Edit", systemImage: "pencil")
            }
            Button(role: .destructive, action: onDelete) {
                DestructiveLabel(text: "Delete")
            }
            .tint(.red)
        } preview: {
            RowPreviewCard(
                icon: "doc.text.fill",
                iconColor: .indigo,
                title: registry.name,
                badges: [
                    .init(text: registry.enabled ? "Enabled" : "Disabled",
                          color: registry.enabled ? .green : .secondary)
                ],
                details: detailRows
            )
        }
    }

    private var detailRows: [RowPreviewCard.PreviewDetail] {
        var rows: [RowPreviewCard.PreviewDetail] = [
            .init(icon: "link", label: "URL", value: registry.url)
        ]
        if let error = registry.lastFetchError, !error.isEmpty {
            rows.append(.init(icon: "exclamationmark.triangle", label: "Last Fetch Error", value: error))
        }
        return rows
    }
}

