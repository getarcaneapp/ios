import SwiftUI
import Arcane

struct EnvironmentsView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @State private var environments: [ServerEnvironment] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showAddEnvironment = false
    @State private var sortOrder = ListSortOrder.ascending

    private var sortedEnvironments: [ServerEnvironment] {
        environments.sorted {
            sortOrder.areInIncreasingOrder($0.name ?? $0.id, $1.name ?? $1.id)
        }
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
                        NavigationLink(destination: EnvironmentDetailView(environment: env)) {
                            EnvironmentRow(environment: env, isActive: env.id == manager.activeEnvironmentID.rawValue)
                        }
                        .swipeActions(edge: .leading) {
                            if env.id != manager.activeEnvironmentID.rawValue {
                                Button {
                                    manager.setActiveEnvironment(
                                        id: EnvironmentID(rawValue: env.id),
                                        name: env.name ?? env.id
                                    )
                                } label: {
                                    Label("Set Active", systemImage: "checkmark.circle.fill")
                                }
                                .tint(.blue)
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
                Button { Task { await loadEnvironments() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
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
        .refreshable { await loadEnvironments() }
        .sheet(isPresented: $showAddEnvironment) {
            AddEnvironmentView { await loadEnvironments() }
        }
    }

    private func loadEnvironments() async {
        guard let client = manager.client else { return }
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            environments = try await client.rest.get("environments")
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct EnvironmentRow: View {
    let environment: ServerEnvironment
    var isActive: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.title3)
                .foregroundStyle(environment.isOnline ?? false ? .green : .secondary)
                .frame(width: 36, height: 36)
                .glassEffect(.regular, in: .circle)

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
                            .background(.blue, in: .capsule)
                    }
                }
                if let url = environment.url {
                    Text(url)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
            StatusBadge(status: environment.status ?? "unknown")
        }
        .padding(.vertical, 4)
    }
}

struct AddEnvironmentView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
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
                    TextField("Name", text: $name)
                    TextField("URL (e.g. tcp://192.168.1.10:2375)", text: $url)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
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
            let _: ServerEnvironment = try await client.rest.post("environments", body: body)
            await onSuccess()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
