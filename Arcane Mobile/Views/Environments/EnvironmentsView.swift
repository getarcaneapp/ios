import SwiftUI
import Arcane

struct EnvironmentsView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutationStore
    @State private var environments: [Arcane.Environment] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showAddEnvironment = false
    @State private var sortOrder = ListSortOrder.ascending

    private var sortedEnvironments: [Arcane.Environment] {
        environments.sorted {
            sortOrder.areInIncreasingOrder($0.name ?? $0.id, $1.name ?? $1.id)
        }
    }

    private var mutationVersion: Int {
        mutationStore.version(kind: .environments)
    }

    var body: some View {
        Group {
            if isLoading && environments.isEmpty {
                ProgressView("Loading environments...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage, environments.isEmpty {
                ContentUnavailableView(
                    "Unable to load environments",
                    systemImage: "server.rack",
                    description: Text(error)
                )
            } else if environments.isEmpty {
                ContentUnavailableView(
                    "No Environments",
                    systemImage: "server.rack",
                    description: Text("Add an environment to get started")
                )
            } else {
                List {
                    ForEach(sortedEnvironments) { env in
                        let isActive = env.id == manager.activeEnvironmentID.rawValue
                        NavigationLink(destination: EnvironmentDetailView(environment: env)) {
                            EnvironmentRow(environment: env, isActive: isActive)
                        }
                        .contextMenu {
                            if !isActive {
                                Button {
                                    manager.setActiveEnvironment(
                                        id: EnvironmentID(rawValue: env.id),
                                        name: env.name ?? env.id
                                    )
                                } label: {
                                    Label("Set Active", systemImage: "checkmark.circle.fill")
                                }
                            }
                        } preview: {
                            environmentPreview(env, isActive: isActive)
                        }
                        .swipeActions(edge: .leading) {
                            if !isActive {
                                Button {
                                    manager.setActiveEnvironment(
                                        id: EnvironmentID(rawValue: env.id),
                                        name: env.name ?? env.id
                                    )
                                } label: {
                                    Label("Set Active", systemImage: "checkmark.circle.fill")
                                }
                                .tint(Color.accentColor)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Environments")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Picker("Sort", selection: $sortOrder) {
                        ForEach(ListSortOrder.allCases) { order in
                            Label(order.title, systemImage: order.systemImage).tag(order)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showAddEnvironment = true } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .task { await loadEnvironments() }
        .refreshable { await loadEnvironments(refresh: true) }
        .sheet(isPresented: $showAddEnvironment) {
            AddEnvironmentView {}
        }
        .onChange(of: mutationVersion) { _, _ in
            Task { await loadEnvironments(refresh: true) }
        }
    }

    private func environmentPreview(_ env: Arcane.Environment, isActive: Bool) -> some View {
        let online = env.isOnline ?? false
        var badges: [RowPreviewCard.PreviewBadge] = [
            .init(text: env.status.capitalized, color: online ? .green : .secondary)
        ]
        if isActive {
            badges.insert(.init(text: "Active", color: .accentColor), at: 0)
        }
        var details: [RowPreviewCard.PreviewDetail] = []
        let envURL = env.apiUrl
        if !envURL.isEmpty {
            details.append(.init(icon: "link", label: "URL", value: envURL))
        }
        details.append(.init(icon: "number", label: "ID", value: env.id))
        return RowPreviewCard(
            icon: "server.rack",
            iconColor: online ? .green : .secondary,
            title: env.name ?? env.id,
            badges: badges,
            details: details
        )
    }

    private func loadEnvironments(refresh: Bool = false) async {
        guard let cached = manager.cached else { return }
        if environments.isEmpty { isLoading = true }
        errorMessage = nil
        defer { isLoading = false }
        do {
            if let result: [Arcane.Environment] = try await cached.getListGlobal(
                "environments", elementType: Arcane.Environment.self, policy: .environments,
                refresh: refresh,
                onFresh: { fresh in environments = fresh }
            ) {
                environments = result
            }
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }
}

struct EnvironmentRow: View {
    let environment: Arcane.Environment
    var isActive: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.title3)
                .foregroundStyle(environment.isOnline ?? false ? .green : .secondary)
                .frame(width: 36, height: 36)
                .glassEffectCompat(in: .circle)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(environment.name ?? environment.id)
                        .font(.headline)
                    if isActive {
                        Text("Active")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor, in: .capsule)
                    }
                }
                if !environment.apiUrl.isEmpty {
                    Text(environment.apiUrl)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
            StatusBadge(status: environment.status)
        }
        .padding(.vertical, 4)
    }
}

struct AddEnvironmentView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutationStore
    @SwiftUI.Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var url = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    let onSuccess: () async -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Environment Details") {
                    FormTextField(
                        title: "Name",
                        placeholder: "Production",
                        text: $name,
                        helper: "This is the display name shown throughout Arcane."
                    )
                    FormTextField(
                        title: "Docker Endpoint",
                        placeholder: "tcp://192.168.1.10:2375",
                        text: $url,
                        keyboardType: .URL,
                        textContentType: .URL,
                        autocapitalization: .never,
                        autocorrectionDisabled: true,
                        helper: "Use the Docker API endpoint reachable from the Arcane server."
                    )
                }
                if let error = errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add Environment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await addEnvironment() } }
                        .disabled(name.isEmpty || isLoading)
                }
            }
        }
    }

    private func addEnvironment() async {
        guard let client = manager.client else { return }
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            let body: [String: String] = ["name": name, "url": url]
            let _: Arcane.Environment = try await client.rest.post("environments", body: body)
            if let cached = manager.cached {
                await cached.invalidateGlobal(paths: ["environments"])
            }
            mutationStore.markChanged(kind: .environments)
            await onSuccess()
            dismiss()
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }
}
