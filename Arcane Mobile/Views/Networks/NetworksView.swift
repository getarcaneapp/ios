import SwiftUI
import Arcane

struct NetworksView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    let environmentID: EnvironmentID
    let environmentName: String

    @State private var networks: [NetworkInfo] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var showCreateSheet = false
    @State private var showPruneConfirm = false
    @State private var showFilterSheet = false
    @State private var typeFilter = NetworkTypeFilter.all
    @State private var sortOrder = ListSortOrder.ascending

    private enum NetworkTypeFilter: String, CaseIterable {
        case all = "All", standard = "Standard", internalOnly = "Internal"
    }

    private var activeFilterCount: Int { typeFilter != .all ? 1 : 0 }

    private var filtered: [NetworkInfo] {
        networks.filter { network in
            let matchesSearch = searchText.isEmpty ||
                network.name.localizedCaseInsensitiveContains(searchText) ||
                network.driver.localizedCaseInsensitiveContains(searchText)
            let matchesType = typeFilter == .all
                || (typeFilter == .standard && !network.isInternal)
                || (typeFilter == .internalOnly && network.isInternal)
            return matchesSearch && matchesType
        }
        .sorted {
            sortOrder.areInIncreasingOrder($0.name, $1.name)
        }
    }

    var body: some View {
        Group {
            if isLoading && networks.isEmpty {
                ProgressView("Loading networks...").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage, networks.isEmpty {
                ContentUnavailableView("Error", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if networks.isEmpty {
                ContentUnavailableView("No Networks", systemImage: "network", description: Text("No networks found"))
            } else {
                List {
                    ForEach(filtered) { network in
                        NavigationLink(destination: NetworkDetailView(network: network, environmentID: environmentID)) {
                            NetworkRow(network: network)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { await deleteNetwork(network) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Networks")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search networks")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Picker("Sort", selection: $sortOrder) {
                        ForEach(ListSortOrder.allCases) { order in
                            Label(order.title, systemImage: order.systemImage).tag(order)
                        }
                    }
                    Button {
                        showFilterSheet = true
                    } label: {
                        Label(activeFilterCount > 0 ? "Filter (\(activeFilterCount))" : "Filter…", systemImage: "line.3.horizontal.decrease.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showCreateSheet = true } label: {
                    Image(systemName: "plus")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showPruneConfirm = true } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .task { await loadNetworks() }
        .refreshable { await loadNetworks() }
        .sheet(isPresented: $showCreateSheet) {
            CreateNetworkView(environmentID: environmentID) { await loadNetworks() }
        }
        .alert("Prune Networks", isPresented: $showPruneConfirm) {
            Button("Prune", role: .destructive) { Task { await pruneNetworks() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Remove all unused networks.")
        }
        .sheet(isPresented: $showFilterSheet) {
            NavigationStack {
                Form {
                    Section("Type") {
                        Picker("Type", selection: $typeFilter) {
                            ForEach(NetworkTypeFilter.allCases, id: \.self) { f in
                                Text(f.rawValue).tag(f)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                }
                .navigationTitle("Filter")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showFilterSheet = false }
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }

    private func loadNetworks() async {
        guard let client = manager.client else { return }
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            let path = client.rest.environmentPath(environmentID, "networks")
            networks = try await client.rest.get(path)
        } catch { errorMessage = friendlyErrorMessage(error) }
    }

    private func deleteNetwork(_ network: NetworkInfo) async {
        guard let client = manager.client else { return }
        do {
            let path = client.rest.environmentPath(environmentID, "networks/\(network.id)")
            let _: DataResponse<String> = try await client.rest.delete(path)
            networks.removeAll { $0.id == network.id }
        } catch {}
    }

    private func pruneNetworks() async {
        guard let client = manager.client else { return }
        do {
            let path = client.rest.environmentPath(environmentID, "networks/prune")
            let _: DataResponse<String> = try await client.rest.post(path, body: String?.none)
            await loadNetworks()
        } catch {}
    }
}

struct NetworkRow: View {
    let network: NetworkInfo

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "network")
                .font(.title3)
                .foregroundStyle(.teal)
                .frame(width: 36, height: 36)
                .glassEffect(.regular, in: .circle)

            VStack(alignment: .leading, spacing: 3) {
                Text(network.name)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(network.driver)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if network.isInternal {
                        Text("• Internal").font(.caption).foregroundStyle(.orange)
                    }
                }
            }

            Spacer()

            if network.containerCount > 0 {
                Text("\(network.containerCount)")
                    .font(.caption.bold())
                    .foregroundStyle(.teal)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .glassEffect(.regular, in: .capsule)
            }
        }
        .padding(.vertical, 2)
    }
}

struct NetworkDetailView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    let network: NetworkInfo
    let environmentID: EnvironmentID

    @State private var showDeleteConfirm = false

    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    Image(systemName: "network")
                        .font(.title)
                        .foregroundStyle(.teal)
                        .frame(width: 56, height: 56)
                        .glassEffect(.regular, in: .circle)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(network.name).font(.title3.bold())
                        Text(network.driver).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Details") {
                LabeledContent("ID", value: String(network.id.prefix(12)))
                LabeledContent("Driver", value: network.driver)
                LabeledContent("Scope", value: network.scope.capitalized)
                if network.isInternal { LabeledContent("Internal", value: "Yes") }
                if let attachable = network.attachable { LabeledContent("Attachable", value: attachable ? "Yes" : "No") }
            }

            if let ipam = network.ipam {
                Section("IPAM") {
                    if let driver = ipam.driver { LabeledContent("Driver", value: driver) }
                    ForEach(ipam.config ?? [], id: \.subnet) { config in
                        if let subnet = config.subnet { LabeledContent("Subnet", value: subnet) }
                        if let gw = config.gateway { LabeledContent("Gateway", value: gw) }
                    }
                }
            }

            if let containers = network.containers, !containers.isEmpty {
                Section("Connected Containers (\(containers.count))") {
                    ForEach(Array(containers.keys.sorted()), id: \.self) { key in
                        if let c = containers[key] {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.name ?? String(key.prefix(12))).font(.headline)
                                if let ip = c.iPv4Address, !ip.isEmpty {
                                    Text(ip).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }

        }
        .listStyle(.insetGrouped)
        .navigationTitle(network.name.isEmpty ? network.id : network.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
            }
        }
        .confirmationDialog("Delete Network", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {}
        }
    }
}

struct CreateNetworkView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let environmentID: EnvironmentID
    let onSuccess: () async -> Void

    @State private var name = ""
    @State private var driver = "bridge"
    @State private var isInternal = false
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Network Details") {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("Driver", selection: $driver) {
                        Text("Bridge").tag("bridge")
                        Text("Host").tag("host")
                        Text("Overlay").tag("overlay")
                        Text("Macvlan").tag("macvlan")
                        Text("None").tag("none")
                    }
                    Toggle("Internal", isOn: $isInternal)
                }
                if let error = errorMessage {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
            }
            .navigationTitle("Create Network")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await createNetwork() } }
                        .disabled(name.isEmpty || isLoading)
                }
            }
        }
    }

    private func createNetwork() async {
        guard let client = manager.client else { return }
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            let body: [String: AnyCodable] = [
                "name": AnyCodable(name),
                "driver": AnyCodable(driver),
                "internal": AnyCodable(isInternal)
            ]
            let path = client.rest.environmentPath(environmentID, "networks")
            let _: NetworkInfo = try await client.rest.post(path, body: body)
            await onSuccess(); dismiss()
        } catch { errorMessage = friendlyErrorMessage(error) }
    }
}
