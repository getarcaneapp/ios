import SwiftUI
import Observation
import Arcane

struct SwarmView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager

    let environmentID: EnvironmentID
    let environmentName: String

    @State private var store = SwarmStore()
    @State private var selectedSection: SwarmSection = .cluster
    @State private var selectedNode: SwarmNode?
    @State private var showsInitialize = false
    @State private var showsJoin = false
    @State private var showsLeave = false
    @State private var showsEasyJoin = false
    @State private var searchText = ""

    private var canRead: Bool {
        manager.permissions.has(Permission.Swarm.read, in: environmentID)
    }

    private var canInitialize: Bool {
        manager.permissions.has(Permission.Swarm.initialize, in: environmentID)
    }

    private var canLeave: Bool {
        manager.permissions.has(Permission.Swarm.leave, in: environmentID)
    }

    private var canJoin: Bool {
        manager.permissions.has(Permission.Swarm.join, in: environmentID)
    }

    private var canManageNodes: Bool {
        manager.permissions.has(Permission.Swarm.nodes, in: environmentID)
    }

    private var filteredNodes: [SwarmNode] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.nodes }
        return store.nodes.filter { node in
            node.hostname.localizedCaseInsensitiveContains(query)
                || node.id.localizedCaseInsensitiveContains(query)
                || node.role.localizedCaseInsensitiveContains(query)
                || node.status.localizedCaseInsensitiveContains(query)
                || (node.agent.environmentName?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        Group {
            if !canRead {
                ContentUnavailableView {
                    Label("Swarm Access Required", systemImage: "lock.fill")
                } description: {
                    Text("Your role cannot view Swarm in this environment.")
                }
            } else {
                VStack(spacing: 0) {
                    Picker("Swarm Section", selection: $selectedSection) {
                        ForEach(SwarmSection.allCases) { section in
                            Label(section.title, systemImage: section.systemImage).tag(section)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.vertical, 10)

                    Divider()

                    switch selectedSection {
                    case .cluster:
                        clusterContent
                    case .nodes:
                        nodesContent
                    }
                }
            }
        }
        .navigationTitle("Swarm")
        .task(id: "\(environmentID.rawValue)#\(manager.clientGeneration)") { await load() }
        .sheet(isPresented: $showsInitialize) {
            InitializeSwarmView { request in
                guard let client = manager.client else {
                    throw ArcaneError.transport("No Arcane client is available")
                }
                try await store.initialize(
                    request,
                    client: client,
                    clientGeneration: manager.clientGeneration,
                    environmentID: environmentID
                )
            }
        }
        .sheet(isPresented: $showsJoin) {
            JoinSwarmView { request in
                guard let client = manager.client else {
                    throw ArcaneError.transport("No Arcane client is available")
                }
                try await store.join(
                    request,
                    client: client,
                    clientGeneration: manager.clientGeneration,
                    environmentID: environmentID
                )
            }
        }
        .sheet(isPresented: $showsLeave) {
            LeaveSwarmView { force in
                guard let client = manager.client else {
                    throw ArcaneError.transport("No Arcane client is available")
                }
                try await store.leave(force: force, client: client, environmentID: environmentID)
            }
        }
        .sheet(isPresented: $showsEasyJoin) {
            EasyJoinView(
                environmentID: environmentID,
                onComplete: { await load() },
                onUnsupported: { store.markEasyJoinUnsupported() }
            )
            .environment(manager)
            .toastHost(reservesTabBarSpace: false)
        }
        .sheet(item: $selectedNode) { node in
            SwarmNodeAgentView(
                node: node,
                environmentID: environmentID,
                canManage: canManageNodes,
                store: store
            ) {
                await store.loadNodes(client: manager.client, environmentID: environmentID)
            }
            .environment(manager)
            .toastHost(reservesTabBarSpace: false)
        }
    }

    @ViewBuilder
    private var clusterContent: some View {
        if store.isLoading && store.status == nil {
            ProgressView("Loading cluster…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.isUnsupported {
            ContentUnavailableView {
                Label("Swarm Unavailable", systemImage: "square.stack.3d.up.slash")
            } description: {
                Text("This Arcane backend does not expose Swarm management.")
            }
        } else if let errorMessage = store.errorMessage, store.status == nil {
            ContentUnavailableView {
                Label("Couldn't Load Swarm", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Try Again") { Task { await load() } }
            }
        } else if store.status?.enabled != true {
            ContentUnavailableView {
                Label("Swarm Is Not Initialized", systemImage: "square.stack.3d.up")
            } description: {
                Text("Initialize a new cluster on \(environmentName), or join this engine to an existing Swarm.")
            } actions: {
                if canInitialize {
                    Button("Initialize Swarm") { showsInitialize = true }
                }
                if canJoin {
                    Button("Join Existing Swarm") { showsJoin = true }
                }
            }
        } else {
            List {
                Section("Cluster") {
                    LabeledContent("Environment", value: environmentName)
                    if let info = store.info {
                        LabeledContent("Cluster ID") {
                            Text(verbatim: info.id)
                                .font(.caption.monospaced())
                                .multilineTextAlignment(.trailing)
                                .textSelection(.enabled)
                        }
                        LabeledContent("Created") {
                            Text(info.createdAt, style: .date)
                        }
                        LabeledContent("Root Rotation") {
                            Text(info.rootRotationInProgress ? "In Progress" : "Idle")
                                .foregroundStyle(info.rootRotationInProgress ? .orange : .secondary)
                        }
                    }
                    LabeledContent("Nodes", value: String(store.nodes.count))
                }

                if let errorMessage = store.errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }

                if canJoin {
                    Section {
                        Button {
                            showsEasyJoin = true
                        } label: {
                            Label("Easy Join", systemImage: "plus.rectangle.on.rectangle")
                        }
                        .disabled(!store.easyJoinSupported)
                        .accessibilityHint("Select Arcane environments to join to this cluster")

                        if !store.easyJoinSupported {
                            Label("Easy Join requires a newer Arcane backend.", systemImage: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Join Environments")
                    } footer: {
                        Text("Easy Join uses each environment's existing Arcane connection and does not reveal Swarm join tokens.")
                    }
                }

                if canLeave {
                    Section {
                        Button(role: .destructive) { showsLeave = true } label: {
                            Label("Leave Swarm", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    } footer: {
                        Text("Leaving removes this Docker engine from the cluster. Force is available for unreachable managers.")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await load() }
        }
    }

    @ViewBuilder
    private var nodesContent: some View {
        if store.isLoading && store.nodes.isEmpty {
            ProgressView("Loading nodes…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.isUnsupported {
            ContentUnavailableView {
                Label("Swarm Unavailable", systemImage: "square.stack.3d.up.slash")
            } description: {
                Text("This Arcane backend does not expose Swarm management.")
            }
        } else if let errorMessage = store.errorMessage, store.status == nil {
            ContentUnavailableView {
                Label("Couldn't Load Swarm", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Try Again") { Task { await load() } }
            }
        } else if store.status?.enabled != true {
            ContentUnavailableView {
                Label("No Swarm Nodes", systemImage: "server.rack")
            } description: {
                Text("Initialize this environment's cluster before managing nodes.")
            }
        } else if let errorMessage = store.nodeErrorMessage, store.nodes.isEmpty {
            ContentUnavailableView {
                Label("Couldn't Load Nodes", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Try Again") { Task { await load() } }
            }
        } else if store.nodes.isEmpty {
            ContentUnavailableView {
                Label("No Nodes", systemImage: "server.rack")
            } description: {
                Text("No nodes are currently visible in this cluster.")
            }
        } else {
            List {
                if canManageNodes, !store.agentLifecycleSupported {
                    Section {
                        Label("Node-agent lifecycle actions require a newer Arcane backend.", systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    if filteredNodes.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                    } else {
                        ForEach(filteredNodes) { node in
                            Button {
                                selectedNode = node
                            } label: {
                                SwarmNodeRow(node: node)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Opens node and agent details")
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $searchText, prompt: "Search nodes")
            .refreshable { await load() }
            .toolbar {
                if canManageNodes {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            Task { await reconcileNodeAgents() }
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        .disabled(store.isReconciling || !store.agentLifecycleSupported)
                        .accessibilityLabel("Reconcile node agents")
                    }
                }
            }
        }
    }

    private func load() async {
        guard let client = manager.client else { return }
        await store.load(
            client: client,
            clientGeneration: manager.clientGeneration,
            environmentID: environmentID
        )
    }

    private func reconcileNodeAgents() async {
        guard let client = manager.client else { return }
        do {
            let supported = try await store.reconcileNodeAgents(client: client, environmentID: environmentID)
            if supported {
                showToast(.success("Node agents reconciled"))
            } else {
                showToast(.info("Node-agent reconciliation is unavailable on this backend"))
            }
        } catch {
            showToast(.error(friendlyErrorMessage(error)))
        }
    }
}

private enum SwarmSection: String, CaseIterable, Identifiable {
    case cluster
    case nodes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cluster: "Cluster"
        case .nodes: "Nodes"
        }
    }

    var systemImage: String {
        switch self {
        case .cluster: "square.stack.3d.up"
        case .nodes: "server.rack"
        }
    }
}

private struct SwarmNodeRow: View {
    let node: SwarmNode

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: node.role.lowercased() == "manager" ? "server.rack" : "desktopcomputer")
                .font(.title3)
                .foregroundStyle(node.statusColor)
                .frame(width: 30)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(node.hostname)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(node.status.capitalized)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(node.statusColor)
                }

                Text(verbatim: node.id)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)

                HStack(spacing: 10) {
                    Label(node.role.capitalized, systemImage: "person.badge.shield.checkmark")
                    Label(node.availability.capitalized, systemImage: "gauge.with.dots.needle.33percent")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Label(node.agent.displayLabel, systemImage: node.agent.systemImage)
                    .font(.caption)
                    .foregroundStyle(node.agent.color)
            }
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

private struct InitializeSwarmView: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let onInitialize: (SwarmInitRequest) async throws -> Void

    @State private var listenAddress = ""
    @State private var advertiseAddress = ""
    @State private var dataPathAddress = ""
    @State private var autoLockManagers = false
    @State private var forceNewCluster = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Network") {
                    FormTextField(
                        title: "Listen Address",
                        placeholder: "0.0.0.0:2377",
                        text: $listenAddress,
                        autocapitalization: .never,
                        autocorrectionDisabled: true
                    )
                    FormTextField(
                        title: "Advertise Address",
                        placeholder: "Optional",
                        text: $advertiseAddress,
                        autocapitalization: .never,
                        autocorrectionDisabled: true
                    )
                    FormTextField(
                        title: "Data Path Address",
                        placeholder: "Optional",
                        text: $dataPathAddress,
                        autocapitalization: .never,
                        autocorrectionDisabled: true
                    )
                }

                Section {
                    Toggle("Auto-lock Managers", isOn: $autoLockManagers)
                    Toggle("Force New Cluster", isOn: $forceNewCluster)
                } footer: {
                    Text("Force New Cluster should only be used to recover an existing engine from lost manager quorum.")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Initialize Swarm")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await initialize() }
                    } label: {
                        if isSaving { ProgressView() } else { Text("Initialize") }
                    }
                    .disabled(isSaving)
                }
            }
            .interactiveDismissDisabled(isSaving)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func initialize() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await onInitialize(
                SwarmInitRequest(
                    listenAddr: listenAddress.nilIfEmpty,
                    advertiseAddr: advertiseAddress.nilIfEmpty,
                    dataPathAddr: dataPathAddress.nilIfEmpty,
                    forceNewCluster: forceNewCluster,
                    spec: .object([:]),
                    autoLockManagers: autoLockManagers,
                    availability: "active"
                )
            )
            showToast(.success("Swarm initialized"))
            dismiss()
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }
}

private struct JoinSwarmView: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let onJoin: (SwarmJoinRequest) async throws -> Void

    @State private var joinToken = ""
    @State private var remoteAddresses = ""
    @State private var listenAddress = ""
    @State private var advertiseAddress = ""
    @State private var dataPathAddress = ""
    @State private var availability = "active"
    @State private var isJoining = false
    @State private var errorMessage: String?

    private var parsedRemoteAddresses: [String] {
        remoteAddresses
            .split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var canJoin: Bool {
        !joinToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !parsedRemoteAddresses.isEmpty
            && !isJoining
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Join Token", text: $joinToken)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField(
                        "Manager addresses, separated by commas or lines",
                        text: $remoteAddresses,
                        axis: .vertical
                    )
                    .lineLimit(2...5)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                } header: {
                    Text("Existing Swarm")
                } footer: {
                    Text("Enter at least one manager address, including port 2377 when required. The join token is never displayed or copied by the app.")
                }

                Section("Node") {
                    Picker("Availability", selection: $availability) {
                        Text("Active").tag("active")
                        Text("Pause").tag("pause")
                        Text("Drain").tag("drain")
                    }

                    FormTextField(
                        title: "Listen Address",
                        placeholder: "Optional",
                        text: $listenAddress,
                        autocapitalization: .never,
                        autocorrectionDisabled: true
                    )
                    FormTextField(
                        title: "Advertise Address",
                        placeholder: "Optional",
                        text: $advertiseAddress,
                        autocapitalization: .never,
                        autocorrectionDisabled: true
                    )
                    FormTextField(
                        title: "Data Path Address",
                        placeholder: "Optional",
                        text: $dataPathAddress,
                        autocapitalization: .never,
                        autocorrectionDisabled: true
                    )
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Join Swarm")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isJoining)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await join() }
                    } label: {
                        if isJoining { ProgressView() } else { Text("Join") }
                    }
                    .disabled(!canJoin)
                }
            }
            .interactiveDismissDisabled(isJoining)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func join() async {
        isJoining = true
        errorMessage = nil
        defer { isJoining = false }

        do {
            try await onJoin(
                SwarmJoinRequest(
                    listenAddr: listenAddress.trimmedNilIfEmpty,
                    advertiseAddr: advertiseAddress.trimmedNilIfEmpty,
                    dataPathAddr: dataPathAddress.trimmedNilIfEmpty,
                    remoteAddrs: parsedRemoteAddresses,
                    joinToken: joinToken.trimmingCharacters(in: .whitespacesAndNewlines),
                    availability: availability
                )
            )
            showToast(.success("Joined Swarm"))
            dismiss()
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }
}

private struct LeaveSwarmView: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let onLeave: (Bool) async throws -> Void

    @State private var force = false
    @State private var isLeaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("This removes the current Docker engine from its Swarm cluster.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Toggle("Force Leave", isOn: $force)
                } footer: {
                    Text("Force leave is intended for recovery when the engine cannot contact a manager.")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Leave Swarm")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isLeaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Leave", role: .destructive) { Task { await leave() } }
                        .disabled(isLeaving)
                }
            }
            .interactiveDismissDisabled(isLeaving)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private func leave() async {
        isLeaving = true
        errorMessage = nil
        defer { isLeaving = false }
        do {
            try await onLeave(force)
            showToast(.success("Left Swarm"))
            dismiss()
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }
}

@MainActor
@Observable
private final class SwarmStore {
    private(set) var status: SwarmRuntimeStatus?
    private(set) var info: SwarmInfo?
    private(set) var nodes: [SwarmNode] = []
    private(set) var isLoading = false
    private(set) var isReconciling = false
    private(set) var isUnsupported = false
    private(set) var agentLifecycleSupported = true
    private(set) var easyJoinSupported = true
    private(set) var errorMessage: String?
    private(set) var nodeErrorMessage: String?

    private var loadedClientGeneration: Int?
    private var loadedEnvironmentID: String?

    func load(
        client: ArcaneClient,
        clientGeneration: Int,
        environmentID: EnvironmentID
    ) async {
        if loadedClientGeneration != clientGeneration
            || loadedEnvironmentID != environmentID.rawValue {
            loadedClientGeneration = clientGeneration
            loadedEnvironmentID = environmentID.rawValue
            status = nil
            info = nil
            nodes = []
            errorMessage = nil
            nodeErrorMessage = nil
            isUnsupported = false
            isReconciling = false
            agentLifecycleSupported = true
            easyJoinSupported = true
        }
        if status == nil { isLoading = true }
        defer { isLoading = false }
        errorMessage = nil
        nodeErrorMessage = nil

        do {
            status = try await client.swarm.status(envID: environmentID)
            isUnsupported = false
        } catch ArcaneError.notFound {
            isUnsupported = true
            status = nil
            info = nil
            nodes = []
            return
        } catch {
            status = nil
            errorMessage = friendlyErrorMessage(error)
            return
        }

        guard status?.enabled == true else {
            info = nil
            nodes = []
            return
        }

        do {
            info = try await client.swarm.info(envID: environmentID)
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }

        await loadNodes(client: client, environmentID: environmentID)
    }

    func loadNodes(client: ArcaneClient?, environmentID: EnvironmentID) async {
        guard let client, status?.enabled == true else { return }
        do {
            let response = try await client.swarm.listNodes(
                envID: environmentID,
                sort: "hostname",
                order: .ascending,
                start: 0,
                limit: 250
            )
            nodes = response.data
            nodeErrorMessage = nil
        } catch {
            nodeErrorMessage = friendlyErrorMessage(error)
        }
    }

    func initialize(
        _ request: SwarmInitRequest,
        client: ArcaneClient,
        clientGeneration: Int,
        environmentID: EnvironmentID
    ) async throws {
        let actionClient = try ActivityBatchID.scopedClient(client)
        _ = try await actionClient.swarm.initSwarm(request, envID: environmentID)
        await load(
            client: client,
            clientGeneration: clientGeneration,
            environmentID: environmentID
        )
    }

    func join(
        _ request: SwarmJoinRequest,
        client: ArcaneClient,
        clientGeneration: Int,
        environmentID: EnvironmentID
    ) async throws {
        let actionClient = try ActivityBatchID.scopedClient(client)
        try await actionClient.swarm.join(request, envID: environmentID)
        await load(
            client: client,
            clientGeneration: clientGeneration,
            environmentID: environmentID
        )
    }

    func leave(force: Bool, client: ArcaneClient, environmentID: EnvironmentID) async throws {
        let actionClient = try ActivityBatchID.scopedClient(client)
        try await actionClient.swarm.leave(force: force, envID: environmentID)
        status = SwarmRuntimeStatus(enabled: false)
        info = nil
        nodes = []
    }

    func reconcileNodeAgents(
        client: ArcaneClient,
        environmentID: EnvironmentID,
        reloadNodes: Bool = true
    ) async throws -> Bool {
        isReconciling = true
        defer { isReconciling = false }
        do {
            let options = try ActivityBatchID.requestOptions()
            _ = try await client.swarm.reconcileNodeAgents(envID: environmentID, options: options)
            if reloadNodes {
                await loadNodes(client: client, environmentID: environmentID)
            }
            return true
        } catch ArcaneError.notFound {
            agentLifecycleSupported = false
            return false
        }
    }

    func markEasyJoinUnsupported() {
        easyJoinSupported = false
    }

    func updateNode(
        nodeID: String,
        role: String,
        availability: String,
        client: ArcaneClient,
        environmentID: EnvironmentID
    ) async throws {
        let actionClient = try ActivityBatchID.scopedClient(client)
        try await actionClient.swarm.updateNode(
            nodeID,
            SwarmNodeUpdateRequest(role: role, availability: availability),
            envID: environmentID
        )
    }

    func deleteNode(
        nodeID: String,
        force: Bool,
        client: ArcaneClient,
        environmentID: EnvironmentID
    ) async throws {
        let actionClient = try ActivityBatchID.scopedClient(client)
        try await actionClient.swarm.deleteNode(nodeID, force: force, envID: environmentID)
    }

    func nodeAgentDeployment(
        nodeID: String,
        rotate: Bool,
        client: ArcaneClient,
        environmentID: EnvironmentID
    ) async throws -> SwarmNodeAgentDeployment {
        let actionClient = try ActivityBatchID.scopedClient(client)
        return try await actionClient.swarm.nodeAgentDeployment(
            nodeID,
            rotate: rotate,
            envID: environmentID
        )
    }

    func bindNodeAgent(
        nodeID: String,
        environmentToBindID: String,
        replaceDeployment: Bool,
        client: ArcaneClient,
        environmentID: EnvironmentID
    ) async throws {
        let options = try ActivityBatchID.requestOptions()
        _ = try await client.swarm.bindNodeAgent(
            nodeID,
            request: SwarmNodeAgentBindingRequest(
                environmentID: environmentToBindID,
                rebind: true,
                replaceDeployment: replaceDeployment
            ),
            envID: environmentID,
            options: options
        )
    }

    func detachNodeAgent(nodeID: String, client: ArcaneClient, environmentID: EnvironmentID) async throws {
        let options = try ActivityBatchID.requestOptions()
        _ = try await client.swarm.detachNodeAgent(nodeID, envID: environmentID, options: options)
    }

    func removeNodeAgentDeployment(nodeID: String, client: ArcaneClient, environmentID: EnvironmentID) async throws {
        let options = try ActivityBatchID.requestOptions()
        _ = try await client.swarm.removeNodeAgentDeployment(nodeID, envID: environmentID, options: options)
    }
}

private extension SwarmNode {
    var statusColor: Color {
        switch status.lowercased() {
        case "ready", "active": .green
        case "down", "disconnected": .red
        default: .orange
        }
    }
}

private extension SwarmNodeAgentStatus {
    var displayLabel: String {
        let stateLabel = state.rawValue.replacingOccurrences(of: "_", with: " ").capitalized
        if let environmentName = environmentName?.nilIfEmpty {
            return "\(stateLabel) · \(environmentName)"
        }
        switch bindingKind {
        case .local: return "\(stateLabel) · Local environment"
        case .dedicated: return "\(stateLabel) · Dedicated agent"
        case .environment: return stateLabel
        case .unknown(let value): return "\(stateLabel) · \(value)"
        case nil: return stateLabel
        }
    }

    var systemImage: String {
        switch state {
        case .connected: "checkmark.circle.fill"
        case .pending: "clock.fill"
        case .offline, .mismatched: "exclamationmark.triangle.fill"
        case .ambiguous: "questionmark.diamond.fill"
        case .none, .unknown: "circle.dashed"
        }
    }

    var color: Color {
        switch state {
        case .connected: .green
        case .pending: .orange
        case .offline, .mismatched: .red
        case .ambiguous: .orange
        case .none, .unknown: .secondary
        }
    }
}

private enum NodeAgentDestructiveAction: Identifiable {
    case attach(environmentID: String)
    case detach
    case removeDeployment
    case removeNode(force: Bool)

    var id: String {
        switch self {
        case .attach(let environmentID): "attach-\(environmentID)"
        case .detach: "detach"
        case .removeDeployment: "remove-deployment"
        case .removeNode(let force): "remove-node-\(force)"
        }
    }
}

private struct SwarmNodeAgentView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.dismiss) private var dismiss

    let node: SwarmNode
    let environmentID: EnvironmentID
    let canManage: Bool
    let store: SwarmStore
    let onUpdated: () async -> Void

    @State private var selectedCandidateID: String
    @State private var deployment: SwarmNodeAgentDeployment?
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var pendingAction: NodeAgentDestructiveAction?
    @State private var showsRegenerateConfirmation = false
    @State private var selectedRole: String
    @State private var selectedAvailability: String
    @State private var forceNodeRemoval = false

    init(
        node: SwarmNode,
        environmentID: EnvironmentID,
        canManage: Bool,
        store: SwarmStore,
        onUpdated: @escaping () async -> Void
    ) {
        self.node = node
        self.environmentID = environmentID
        self.canManage = canManage
        self.store = store
        self.onUpdated = onUpdated
        _selectedCandidateID = State(initialValue: node.agent.candidates.first?.environmentID ?? "")
        _selectedRole = State(initialValue: node.role.lowercased())
        _selectedAvailability = State(initialValue: node.availability.lowercased())
    }

    private var bindingLabel: String {
        switch node.agent.bindingKind {
        case .local: "Local environment"
        case .environment: node.agent.environmentName?.nilIfEmpty ?? node.agent.environmentId ?? "Environment"
        case .dedicated: "Dedicated node agent"
        case .unknown(let value): value.capitalized
        case nil: "Not bound"
        }
    }

    private var hasNodeChanges: Bool {
        selectedRole != node.role.lowercased()
            || selectedAvailability != node.availability.lowercased()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Node") {
                    LabeledContent("Hostname", value: node.hostname)
                    LabeledContent("Node ID") {
                        Text(verbatim: node.id)
                            .font(.caption.monospaced())
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }
                    LabeledContent("Role", value: node.role.capitalized)
                    LabeledContent("Availability", value: node.availability.capitalized)
                    LabeledContent("Docker Status") {
                        Text(node.status.capitalized).foregroundStyle(node.statusColor)
                    }
                }

                Section("Arcane Agent") {
                    LabeledContent("Status") {
                        Label(node.agent.state.rawValue.capitalized, systemImage: node.agent.systemImage)
                            .foregroundStyle(node.agent.color)
                    }
                    LabeledContent("Binding", value: bindingLabel)
                    if let environmentType = node.agent.environmentType?.nilIfEmpty {
                        LabeledContent("Environment Type", value: environmentType.capitalized)
                    }
                    if let lastHeartbeat = node.agent.lastHeartbeat {
                        LabeledContent("Last Heartbeat") {
                            Text(lastHeartbeat, style: .relative)
                        }
                    }
                }

                if canManage {
                    nodeManagementSection

                    if !store.agentLifecycleSupported {
                        Section {
                            Label("Agent lifecycle management requires a newer Arcane backend.", systemImage: "info.circle")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        attachSection
                        deploymentSection
                        destructiveSection
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(node.hostname)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.disabled(isWorking)
                }
            }
            .interactiveDismissDisabled(isWorking)
            .deleteConfirmation(item: $pendingAction) { action in
                confirmation(for: action)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var nodeManagementSection: some View {
        Section {
            Picker("Role", selection: $selectedRole) {
                if selectedRole != "worker", selectedRole != "manager" {
                    Text(selectedRole.capitalized).tag(selectedRole)
                }
                Text("Worker").tag("worker")
                Text("Manager").tag("manager")
            }

            Picker("Availability", selection: $selectedAvailability) {
                if !["active", "pause", "drain"].contains(selectedAvailability) {
                    Text(selectedAvailability.capitalized).tag(selectedAvailability)
                }
                Text("Active").tag("active")
                Text("Pause").tag("pause")
                Text("Drain").tag("drain")
            }

            Button {
                Task { await saveNodeChanges() }
            } label: {
                if isWorking {
                    ProgressView()
                } else {
                    Label("Save Node Changes", systemImage: "checkmark.circle")
                }
            }
            .disabled(!hasNodeChanges || isWorking)

            Toggle("Force Removal", isOn: $forceNodeRemoval)

            Button(role: .destructive) {
                pendingAction = .removeNode(force: forceNodeRemoval)
            } label: {
                Label("Remove Node", systemImage: "trash")
            }
            .disabled(isWorking)
        } header: {
            Text("Node Management")
        } footer: {
            Text("Force removal is intended for nodes that cannot be contacted or cleanly removed from the cluster.")
        }
    }

    @ViewBuilder
    private var attachSection: some View {
        if !node.agent.candidates.isEmpty {
            Section {
                Picker("Environment", selection: $selectedCandidateID) {
                    ForEach(node.agent.candidates) { candidate in
                        Text(candidate.environmentName).tag(candidate.environmentID)
                    }
                }
                .pickerStyle(.menu)

                Button {
                    guard !selectedCandidateID.isEmpty else { return }
                    if node.agent.bindingKind == .dedicated {
                        pendingAction = .attach(environmentID: selectedCandidateID)
                    } else {
                        Task { await attach(to: selectedCandidateID) }
                    }
                } label: {
                    if isWorking {
                        ProgressView()
                    } else {
                        Label("Attach Environment", systemImage: "link")
                    }
                }
                .disabled(isWorking || selectedCandidateID.isEmpty)
            } header: {
                Text("Attach Existing Environment")
            } footer: {
                Text("Attach the Arcane environment that is already running on this Swarm node.")
            }
        }
    }

    @ViewBuilder
    private var deploymentSection: some View {
        if node.agent.bindingKind == nil || node.agent.bindingKind == .dedicated {
            Section {
                if let deployment {
                    DeploymentSnippetRow(
                        title: "Docker Compose",
                        value: deployment.dockerCompose
                    )
                    DeploymentSnippetRow(
                        title: "Docker Run",
                        value: deployment.dockerRun
                    )
                    if let hostDirHint = deployment.mtls?.hostDirHint.nilIfEmpty {
                        LabeledContent("Host Directory", value: hostDirHint)
                    }

                    Button {
                        showsRegenerateConfirmation = true
                    } label: {
                        Label("Regenerate Deployment", systemImage: "arrow.clockwise")
                    }
                    .disabled(isWorking)

                    if showsRegenerateConfirmation {
                        Label(
                            "Regenerating rotates deployment credentials, so previously generated commands may stop working.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)

                        HStack {
                            Button("Cancel") { showsRegenerateConfirmation = false }
                            Spacer()
                            Button("Regenerate", role: .destructive) {
                                showsRegenerateConfirmation = false
                                Task { await loadDeployment(rotate: true) }
                            }
                        }
                    }
                } else {
                    Button {
                        Task { await loadDeployment(rotate: false) }
                    } label: {
                        if isWorking {
                            ProgressView()
                        } else {
                            Label(
                                node.agent.bindingKind == .dedicated ? "Load Deployment" : "Create Dedicated Agent",
                                systemImage: "shippingbox.and.arrow.backward"
                            )
                        }
                    }
                    .disabled(isWorking)
                }
            } header: {
                Text("Dedicated Agent")
            } footer: {
                Text("Deployment commands can contain one-time credentials. Store them securely and do not share them.")
            }
        }
    }

    @ViewBuilder
    private var destructiveSection: some View {
        switch node.agent.bindingKind {
        case .environment:
            Section {
                Button(role: .destructive) {
                    pendingAction = .detach
                } label: {
                    Label("Detach Environment", systemImage: "link.badge.minus")
                }
                .disabled(isWorking)
            }
        case .dedicated:
            Section {
                Button(role: .destructive) {
                    pendingAction = .removeDeployment
                } label: {
                    Label("Remove Dedicated Deployment", systemImage: "trash")
                }
                .disabled(isWorking)
            }
        case .local, .unknown, nil:
            EmptyView()
        }
    }

    private func confirmation(for action: NodeAgentDestructiveAction) -> DeleteConfirmationConfig {
        let title: String
        let message: String
        let buttonTitle: String
        let icon: String
        switch action {
        case .attach:
            title = "Replace Dedicated Agent"
            message = "Attaching this environment removes the dedicated hidden deployment for the node."
            buttonTitle = "Replace and Attach"
            icon = "link"
        case .detach:
            title = "Detach Environment"
            message = "The environment remains in Arcane, but it will no longer be bound to this Swarm node."
            buttonTitle = "Detach"
            icon = "link.badge.minus"
        case .removeDeployment:
            title = "Remove Dedicated Deployment"
            message = "Remove the dedicated hidden node-agent registration from Arcane?"
            buttonTitle = "Remove"
            icon = "trash"
        case .removeNode(let force):
            title = "Remove Node"
            message = force
                ? "Force-remove \(node.hostname) from this Swarm? Use this only when the node cannot be contacted."
                : "Remove \(node.hostname) from this Swarm?"
            buttonTitle = force ? "Force Remove" : "Remove"
            icon = "server.rack"
        }
        return DeleteConfirmationConfig(
            title: title,
            message: message,
            icon: icon,
            actions: [
                DeleteConfirmationAction(title: buttonTitle) {
                    Task { await perform(action) }
                }
            ]
        )
    }

    private func perform(_ action: NodeAgentDestructiveAction) async {
        switch action {
        case .attach(let environmentID):
            await attach(to: environmentID)
        case .detach:
            await detach()
        case .removeDeployment:
            await removeDeployment()
        case .removeNode(let force):
            await removeNode(force: force)
        }
    }

    private func saveNodeChanges() async {
        guard canManage, let client = manager.client else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await store.updateNode(
                nodeID: node.id,
                role: selectedRole,
                availability: selectedAvailability,
                client: client,
                environmentID: environmentID
            )
            await onUpdated()
            showToast(.success("Node updated"))
            dismiss()
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func removeNode(force: Bool) async {
        guard canManage, let client = manager.client else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await store.deleteNode(
                nodeID: node.id,
                force: force,
                client: client,
                environmentID: environmentID
            )
            await onUpdated()
            showToast(.success("Node removed"))
            dismiss()
        } catch {
            showToast(.error(friendlyErrorMessage(error)))
        }
    }

    private func attach(to candidateID: String) async {
        guard let client = manager.client else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await store.bindNodeAgent(
                nodeID: node.id,
                environmentToBindID: candidateID,
                replaceDeployment: node.agent.bindingKind == .dedicated,
                client: client,
                environmentID: environmentID
            )
            await onUpdated()
            showToast(.success("Environment attached"))
            dismiss()
        } catch {
            errorMessage = lifecycleErrorMessage(error)
        }
    }

    private func detach() async {
        guard let client = manager.client else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await store.detachNodeAgent(nodeID: node.id, client: client, environmentID: environmentID)
            await onUpdated()
            showToast(.success("Environment detached"))
            dismiss()
        } catch {
            errorMessage = lifecycleErrorMessage(error)
        }
    }

    private func removeDeployment() async {
        guard let client = manager.client else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await store.removeNodeAgentDeployment(nodeID: node.id, client: client, environmentID: environmentID)
            await onUpdated()
            showToast(.success("Dedicated deployment removed"))
            dismiss()
        } catch {
            errorMessage = lifecycleErrorMessage(error)
        }
    }

    private func loadDeployment(rotate: Bool) async {
        guard let client = manager.client else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            deployment = try await store.nodeAgentDeployment(
                nodeID: node.id,
                rotate: rotate,
                client: client,
                environmentID: environmentID
            )
            if rotate { showToast(.success("Deployment regenerated")) }
        } catch {
            errorMessage = lifecycleErrorMessage(error)
        }
    }

    private func lifecycleErrorMessage(_ error: Error) -> String {
        if (error as? ArcaneError) == .notFound {
            return "The node or agent resource was not found. Refresh and try again."
        }
        return friendlyErrorMessage(error)
    }
}

private struct DeploymentSnippetRow: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    UIPasteboard.general.string = value
                    showToast(.copied("\(title) copied"))
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Copy \(title)")
            }
            ScrollView(.horizontal) {
                Text(value)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct EasyJoinTargetDraft: Hashable {
    var role: SwarmJoinEnvironmentRole = .worker
    var availability = "active"
    var listenAddress = ""
    var advertiseAddress = ""
    var dataPathAddress = ""
}

private struct EasyJoinView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.dismiss) private var dismiss

    let environmentID: EnvironmentID
    let onComplete: () async -> Void
    let onUnsupported: () -> Void

    @State private var candidates: [SwarmJoinCandidate] = []
    @State private var drafts: [String: EasyJoinTargetDraft] = [:]
    @State private var results: [SwarmJoinEnvironmentResult] = []
    @State private var isLoading = true
    @State private var isJoining = false
    @State private var isUnsupported = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                if isLoading {
                    Section {
                        ProgressView("Loading eligible environments…")
                            .frame(maxWidth: .infinity)
                    }
                } else if isUnsupported {
                    Section {
                        ContentUnavailableView {
                            Label("Easy Join Unavailable", systemImage: "square.stack.3d.up.slash")
                        } description: {
                            Text("Update Arcane to join environments without handling Swarm tokens.")
                        }
                    }
                } else if candidates.isEmpty {
                    Section {
                        ContentUnavailableView {
                            Label("No Eligible Environments", systemImage: "server.rack")
                        } description: {
                            Text("All enabled environments are already in a Swarm or are unavailable.")
                        }
                    }
                } else {
                    ForEach(candidates) { candidate in
                        candidateSection(candidate)
                    }
                }

                if !results.isEmpty {
                    Section("Results") {
                        ForEach(results) { result in
                            EasyJoinResultRow(
                                result: result,
                                environmentName: candidates.first(where: { $0.environmentID == result.environmentID })?.environmentName
                            )
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Easy Join")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(results.isEmpty ? "Cancel" : "Done") { dismiss() }
                        .disabled(isJoining)
                }
                if !candidates.isEmpty, !isUnsupported {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            Task { await joinSelected() }
                        } label: {
                            if isJoining { ProgressView() } else { Text("Join") }
                        }
                        .disabled(drafts.isEmpty || isJoining)
                    }
                }
            }
            .interactiveDismissDisabled(isJoining)
            .task { await loadCandidates() }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private func candidateSection(_ candidate: SwarmJoinCandidate) -> some View {
        let canJoinCandidate = manager.permissions.has(
            Permission.Swarm.join,
            in: EnvironmentID(rawValue: candidate.environmentID)
        )
        Section {
            Toggle(
                isOn: Binding(
                    get: { drafts[candidate.environmentID] != nil },
                    set: { selected in
                        if selected {
                            drafts[candidate.environmentID] = EasyJoinTargetDraft()
                        } else {
                            drafts.removeValue(forKey: candidate.environmentID)
                        }
                    }
                )
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.environmentName)
                    Text("\(candidate.environmentType.capitalized) · \(candidate.status.capitalized)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!canJoinCandidate)

            if !canJoinCandidate {
                Label("Your role cannot join this environment to a Swarm.", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if drafts[candidate.environmentID] != nil {
                Picker(
                    "Role",
                    selection: draftBinding(
                        candidate.environmentID,
                        keyPath: \.role,
                        defaultValue: .worker
                    )
                ) {
                    Text("Worker").tag(SwarmJoinEnvironmentRole.worker)
                    Text("Manager").tag(SwarmJoinEnvironmentRole.manager)
                }

                Picker(
                    "Availability",
                    selection: draftBinding(
                        candidate.environmentID,
                        keyPath: \.availability,
                        defaultValue: "active"
                    )
                ) {
                    Text("Active").tag("active")
                    Text("Pause").tag("pause")
                    Text("Drain").tag("drain")
                }

                DisclosureGroup("Network Overrides") {
                    FormTextField(
                        title: "Listen Address",
                        placeholder: "Optional",
                        text: draftBinding(
                            candidate.environmentID,
                            keyPath: \.listenAddress,
                            defaultValue: ""
                        ),
                        autocapitalization: .never,
                        autocorrectionDisabled: true,
                        layout: .stacked
                    )
                    FormTextField(
                        title: "Advertise Address",
                        placeholder: "Optional",
                        text: draftBinding(
                            candidate.environmentID,
                            keyPath: \.advertiseAddress,
                            defaultValue: ""
                        ),
                        autocapitalization: .never,
                        autocorrectionDisabled: true,
                        layout: .stacked
                    )
                    FormTextField(
                        title: "Data Path Address",
                        placeholder: "Optional",
                        text: draftBinding(
                            candidate.environmentID,
                            keyPath: \.dataPathAddress,
                            defaultValue: ""
                        ),
                        autocapitalization: .never,
                        autocorrectionDisabled: true,
                        layout: .stacked
                    )
                }
            }
        }
    }

    private func draftBinding<Value>(
        _ environmentID: String,
        keyPath: WritableKeyPath<EasyJoinTargetDraft, Value>,
        defaultValue: Value
    ) -> Binding<Value> {
        Binding(
            get: { drafts[environmentID]?[keyPath: keyPath] ?? defaultValue },
            set: { newValue in
                var draft = drafts[environmentID] ?? EasyJoinTargetDraft()
                draft[keyPath: keyPath] = newValue
                drafts[environmentID] = draft
            }
        )
    }

    private func loadCandidates() async {
        guard let client = manager.client else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            candidates = try await client.swarm.joinCandidates(envID: environmentID)
                .sorted { $0.environmentName.localizedCaseInsensitiveCompare($1.environmentName) == .orderedAscending }
        } catch ArcaneError.notFound {
            isUnsupported = true
            onUnsupported()
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func joinSelected() async {
        guard let client = manager.client else { return }
        let targets = drafts.sorted { $0.key < $1.key }.map { environmentID, draft in
            SwarmJoinEnvironmentTarget(
                environmentID: environmentID,
                role: draft.role,
                availability: draft.availability,
                listenAddr: draft.listenAddress.nilIfEmpty,
                advertiseAddr: draft.advertiseAddress.nilIfEmpty,
                dataPathAddr: draft.dataPathAddress.nilIfEmpty
            )
        }
        guard !targets.isEmpty else { return }

        isJoining = true
        errorMessage = nil
        results = []
        defer { isJoining = false }
        do {
            let options = try ActivityBatchID.requestOptions()
            let response = try await client.swarm.joinEnvironments(
                SwarmJoinEnvironmentsRequest(targets: targets),
                envID: environmentID,
                options: options
            )
            results = response.results
            await onComplete()
            let failures = results.filter { $0.state == .failed }.count
            if failures == 0 {
                showToast(.success("Selected environments joined"))
            } else {
                showToast(.error("\(failures) environment\(failures == 1 ? "" : "s") failed to join"))
            }
        } catch ArcaneError.notFound {
            isUnsupported = true
            onUnsupported()
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }
}

private struct EasyJoinResultRow: View {
    let result: SwarmJoinEnvironmentResult
    let environmentName: String?

    private var isFailure: Bool { result.state == .failed }

    private var label: String {
        switch result.state {
        case .joined: "Joined"
        case .alreadyMember: "Already a member"
        case .joinedUnverified: "Joined; awaiting verification"
        case .failed: "Failed"
        case .unknown(let value): value.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(environmentName?.nilIfEmpty ?? result.environmentID)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isFailure ? .red : .green)
            }
            if let error = result.error?.nilIfEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if let nodeID = result.nodeID?.nilIfEmpty {
                Text(verbatim: nodeID)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

    var trimmedNilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
