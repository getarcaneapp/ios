import Arcane
import SwiftUI

struct SwarmServiceDetailView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutationStore
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    let serviceID: String
    let environmentID: EnvironmentID

    @State private var summary: SwarmServiceSummary?
    @State private var inspect: SwarmServiceInspect?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedTab: Tab = .overview
    @State private var showScale = false
    @State private var showEdit = false
    @State private var runningActionID: String?

    init(serviceID: String, summary: SwarmServiceSummary? = nil, environmentID: EnvironmentID) {
        self.serviceID = serviceID
        self.environmentID = environmentID
        _summary = State(initialValue: summary)
    }

    private enum Tab: String, CaseIterable, Identifiable {
        case overview, tasks, logs
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var systemImage: String {
            switch self {
            case .overview: "info.circle.fill"
            case .tasks: "checklist"
            case .logs: "text.alignleft"
            }
        }
        var tint: Color {
            switch self {
            case .overview: .purple
            case .tasks: .blue
            case .logs: .teal
            }
        }
    }

    private var draft: SwarmServiceSpecDraft? { inspect.map { SwarmServiceSpecDraft(spec: $0.spec) } }
    private var name: String { draft?.name ?? summary?.name ?? String(serviceID.prefix(12)) }
    private var canManage: Bool { manager.permissions.has(Permission.Swarm.services, in: environmentID) }
    private var canReadLogs: Bool { manager.permissions.has(Permission.Swarm.servicesLogs, in: environmentID) }
    private var swarmVersion: Int { mutationStore.version(kind: .swarm, envID: environmentID) }

    private var tabs: [Tab] { Tab.allCases.filter { $0 != .logs || canReadLogs } }

    var body: some View {
        VStack(spacing: 0) {
            ScrollableTabBar(
                selection: $selectedTab,
                options: tabs.map {
                    ScrollableTabOption($0, title: $0.title, systemImage: $0.systemImage, tint: $0.tint)
                },
                accessibilityLabel: "Service detail sections"
            )
            ZStack {
                switch selectedTab {
                case .overview:
                    overview
                        .transition(.motionAware(edge: .leading, reduceMotion: reduceMotion))
                case .tasks:
                    SwarmTasksView(environmentID: environmentID, source: .service(serviceID))
                        .transition(.opacity)
                case .logs:
                    LogsView(
                        title: name,
                        logStream: {
                            manager.client?.boundedSwarmServiceLogs(
                                envID: environmentID, serviceID: serviceID, timestamps: true)
                        },
                        embedded: true
                    )
                    .transition(.motionAware(edge: .trailing, reduceMotion: reduceMotion))
                }
            }
            .motionAwareAnimation(Motion.state, value: selectedTab)
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .resourceActionsToolbar(
            primary: primaryAction,
            secondary: secondaryActions,
            overflow: overflowActions,
            runningItemID: runningActionID,
            isDisabled: runningActionID != nil || !canManage,
            resourceName: name,
            active: canManage
        )
        .task { await load() }
        .onChange(of: swarmVersion) { _, _ in
            Task { await load() }
        }
        .sheet(isPresented: $showScale) {
            if let summary {
                SwarmScaleSheet(service: summary, environmentID: environmentID)
            }
        }
        .sheet(isPresented: $showEdit) {
            if let inspect {
                SwarmServiceEditorView(environmentID: environmentID, existing: inspect)
            }
        }
    }

    // MARK: - Overview

    private var overview: some View {
        List {
            Section { header }
            if let errorMessage, inspect == nil {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Button("Retry") { Task { await load() } }
                }
            }
            detailsSection
            if let status = inspect?.updateStatus, let state = status["State"]?.swarmString {
                Section("Last Update") {
                    LabeledContent("State") { SwarmStateBadge(state: state) }
                    if let message = status["Message"]?.swarmString, !message.isEmpty {
                        Text(verbatim: message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let draft {
                configSection(draft)
                portsSection(draft)
            }
            networksSection
            mountsSection
        }
        .listStyle(.insetGrouped)
        .softTopScrollEdgeEffectCompat()
        .refreshable { await load() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "shippingbox.fill")
                .font(.title)
                .foregroundStyle(.tint)
                .frame(width: 52, height: 52)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: name)
                    .font(.title3.bold())
                Text(verbatim: draft?.image ?? summary?.image ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if let summary {
                    Text(verbatim: "\(summary.runningReplicas)/\(summary.replicas) running")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(
                            summary.mode != "replicated" || summary.runningReplicas >= summary.replicas
                                ? .green : .orange)
                }
            }
        }
    }

    private var detailsSection: some View {
        Section("Details") {
            LabeledContent("ID") { MonospacedValue(value: String(serviceID.prefix(12))) }
            if let mode = draft?.mode ?? summary.map({ SwarmServiceSpecDraft.Mode(rawValue: $0.mode) ?? .job }) {
                LabeledContent("Mode", value: mode.rawValue.capitalized)
            }
            if let stack = summary?.stackName, !stack.isEmpty {
                LabeledContent("Stack", value: stack)
            }
            if let nodes = inspect?.nodes ?? summary?.nodes, !nodes.isEmpty {
                LabeledContent("Nodes") { Text(verbatim: String(nodes.count)) }
            }
            if let version = inspect?.version.swarmVersionIndex {
                LabeledContent("Version") { Text(verbatim: String(version)).monospacedDigit() }
            }
            if let created = inspect?.createdAt ?? summary?.createdAt {
                LabeledContent("Created", value: SwarmPresentation.date(created))
            }
            if let updated = inspect?.updatedAt ?? summary?.updatedAt {
                LabeledContent("Updated", value: SwarmPresentation.date(updated))
            }
        }
    }

    @ViewBuilder
    private func configSection(_ draft: SwarmServiceSpecDraft) -> some View {
        let hasRows =
            !draft.command.isEmpty || !draft.args.isEmpty || !draft.workingDir.isEmpty || !draft.user.isEmpty
            || !draft.env.isEmpty || !draft.labels.isEmpty
        if hasRows {
            Section("Configuration") {
                if !draft.command.isEmpty {
                    LabeledContent("Command") { MonospacedValue(value: draft.command) }
                }
                if !draft.args.isEmpty {
                    LabeledContent("Args") { MonospacedValue(value: draft.args) }
                }
                if !draft.workingDir.isEmpty {
                    LabeledContent("Working Dir") { MonospacedValue(value: draft.workingDir) }
                }
                if !draft.user.isEmpty {
                    LabeledContent("User", value: draft.user)
                }
                if !draft.env.isEmpty {
                    NavigationLink {
                        EnvVarsView(vars: draft.env.map { "\($0.key)=\($0.value)" })
                    } label: {
                        Label("Environment (\(draft.env.count))", systemImage: "list.bullet.rectangle")
                    }
                }
                if !draft.labels.isEmpty {
                    NavigationLink {
                        LabelsView(labels: Dictionary(draft.labels.map { ($0.key, $0.value) }) { first, _ in first })
                    } label: {
                        Label("Labels (\(draft.labels.count))", systemImage: "tag")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func portsSection(_ draft: SwarmServiceSpecDraft) -> some View {
        let virtualIPs = (inspect?.endpoint["VirtualIPs"]?.swarmArray ?? []).compactMap { $0["Addr"]?.swarmString }
        if !draft.ports.isEmpty || !virtualIPs.isEmpty {
            Section("Endpoints") {
                ForEach(draft.ports) { port in
                    LabeledContent {
                        Text(verbatim: port.published.isEmpty ? "Not published" : port.published)
                            .font(.callout.monospaced())
                    } label: {
                        Text(verbatim: "\(port.target)/\(port.proto)")
                            .font(.callout.monospaced())
                    }
                }
                ForEach(virtualIPs, id: \.self) { address in
                    LabeledContent("Virtual IP") { MonospacedValue(value: address) }
                }
            }
        }
    }

    @ViewBuilder
    private var networksSection: some View {
        let details = (inspect?.networkDetails ?? [:]).values.sorted { $0.name < $1.name }
        if !details.isEmpty {
            Section("Networks") {
                ForEach(details) { network in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: network.name)
                            .font(.subheadline.weight(.semibold))
                        Text(
                            verbatim: [network.driver, network.scope, network.ingress ? "ingress" : nil]
                                .compactMap { $0 }.joined(separator: " · ")
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        ForEach(Array((network.ipamConfigs ?? []).enumerated()), id: \.offset) { _, config in
                            if let subnet = config.subnet {
                                Text(verbatim: subnet)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        } else if let networks = summary?.networks, !networks.isEmpty {
            Section("Networks") {
                ForEach(networks, id: \.self) { network in
                    Text(verbatim: network)
                }
            }
        }
    }

    @ViewBuilder
    private var mountsSection: some View {
        let mounts = inspect?.mounts ?? summary?.mounts ?? []
        if !mounts.isEmpty {
            Section("Storage") {
                ForEach(Array(mounts.enumerated()), id: \.offset) { _, mount in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: mount.target)
                            .font(.callout.monospaced())
                        Text(
                            verbatim: [
                                mount.type, mount.source, mount.readOnly == true ? "read-only" : "read-write",
                            ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .textSelection(.enabled)
                }
            }
        }
    }

    // MARK: - Actions

    private var isReplicated: Bool { (draft?.mode ?? .replicated) == .replicated && summary != nil }

    private var primaryAction: ActionButtonItem? {
        guard canManage else { return nil }
        if isReplicated {
            return ActionButtonItem(id: "scale", title: "Scale", systemImage: "plusminus", tint: .accentColor) {
                showScale = true
            }
        }
        return editAction
    }

    private var editAction: ActionButtonItem {
        ActionButtonItem(id: "edit", title: "Edit", systemImage: "slider.horizontal.3", tint: .accentColor) {
            showEdit = true
        }
    }

    private var secondaryActions: [ActionButtonItem] {
        guard canManage else { return [] }
        var items: [ActionButtonItem] = []
        if isReplicated, inspect != nil { items.append(editAction) }
        items.append(
            ActionButtonItem(
                id: "rollback",
                title: "Rollback",
                systemImage: "arrow.uturn.backward",
                tint: .orange,
                confirmationMessage: "Roll the service back to its previous spec."
            ) {
                Task { await rollback() }
            })
        return items
    }

    private var overflowActions: [ActionButtonItem] {
        guard canManage else { return [] }
        return [
            ActionButtonItem(
                id: "delete",
                title: "Delete",
                systemImage: "trash",
                tint: .red,
                role: .destructive,
                confirmationMessage: "This stops and removes every task of the service."
            ) {
                Task { await delete() }
            }
        ]
    }

    private func load() async {
        guard let client = manager.client, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            inspect = try await client.swarm.service(serviceID, envID: environmentID)
            errorMessage = nil
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
        // Replica counts only come from the list endpoint.
        if let name = draft?.name ?? summary?.name,
            let response = try? await client.swarm.listServices(envID: environmentID, search: name, limit: 50)
        {
            summary = response.data.first { $0.id == serviceID } ?? summary
        }
    }

    private func rollback() async {
        guard let client = manager.client else { return }
        runningActionID = "rollback"
        defer { runningActionID = nil }
        do {
            let response = try await client.swarm.rollbackService(serviceID, envID: environmentID)
            await manager.swarmChanged(environmentID, mutationStore: mutationStore)
            showToast(.success("Rollback started"))
            if let warning = response.warnings?.first { showToast(.info(warning)) }
        } catch {
            showToast(.error(friendlyErrorMessage(error)))
        }
    }

    private func delete() async {
        guard let client = manager.client else { return }
        runningActionID = "delete"
        defer { runningActionID = nil }
        do {
            try await client.swarm.deleteService(serviceID, envID: environmentID)
            await manager.swarmChanged(environmentID, mutationStore: mutationStore)
            showToast(.success("Service deleted"))
            dismiss()
        } catch {
            showToast(.error(friendlyErrorMessage(error)))
        }
    }
}
