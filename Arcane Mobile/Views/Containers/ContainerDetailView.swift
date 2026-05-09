import SwiftUI
import Arcane

struct ContainerDetailView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    let container: ContainerInfo
    let environmentID: EnvironmentID

    @State private var details: ContainerDetails?
    @State private var isLoading = false
    @State private var isActioning = false
    @State private var errorMessage: String?
    @State private var showLogs = false
    @State private var showTerminal = false
    @State private var showRename = false
    @State private var showDeleteConfirm = false
    @State private var showKillConfirm = false
    @State private var selectedTab: DetailTab = .overview

    private enum DetailTab: String, CaseIterable, Identifiable {
        case overview, stats, inspect
        var id: String { rawValue }
        var title: String {
            switch self {
            case .overview: return "Overview"
            case .stats: return "Stats"
            case .inspect: return "Inspect"
            }
        }
    }

    private var statusString: String {
        details?.state.status ?? container.status
    }

    private var isRunning: Bool {
        if let running = details?.state.running { return running }
        return container.isRunning
    }

    private var isPaused: Bool {
        statusString.lowercased() == "paused"
    }

    private var displayedName: String {
        if let name = details?.name {
            let trimmed = name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !trimmed.isEmpty { return trimmed }
        }
        return container.displayName
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $selectedTab) {
                ForEach(DetailTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 4)

            switch selectedTab {
            case .overview:
                overviewTab
            case .stats:
                ContainerStatsView(container: container, environmentID: environmentID)
            case .inspect:
                ContainerInspectView(container: container, environmentID: environmentID)
            }
        }
        .navigationTitle(displayedName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        showRename = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        DestructiveLabel(text: "Delete")
                    }
                    .tint(.red)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(isActioning)
            }
        }
        .task { await loadDetails() }
        .refreshable { await loadDetails() }
        .sheet(isPresented: $showLogs) {
            LogsView(
                title: displayedName,
                logStream: manager.client?.containers.logs(envID: environmentID, id: container.id)
            )
        }
        .fullScreenCover(isPresented: $showTerminal) {
            ContainerTerminalView(container: container, environmentID: environmentID)
        }
        .sheet(isPresented: $showRename) {
            RenameContainerSheet(currentName: displayedName) { newName in
                await renameContainer(newName: newName)
            }
        }
        .confirmationDialog("Delete Container", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task { await deleteContainer() }
            }
        } message: {
            Text("This will permanently delete the container and cannot be undone.")
        }
        .confirmationDialog("Kill Container", isPresented: $showKillConfirm, titleVisibility: .visible) {
            Button("Kill (SIGKILL)", role: .destructive) {
                Task { await performAction(.kill) }
            }
        } message: {
            Text("Sends SIGKILL — the container is terminated immediately without graceful shutdown. Use Stop for a graceful shutdown.")
        }
        .alert("Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Overview tab

    private var overviewTab: some View {
        List {
            Section {
                statusHeader
            }

            Section("Actions") {
                actionsSection
            }

            if let details {
                configSection(details.config)
                stateSection(details.state)
                hostConfigSection(details.hostConfig)
                if let ports = details.ports, !ports.isEmpty {
                    ContainerPortsSection(ports: ports)
                }
                if let health = details.state.health {
                    ContainerHealthSection(health: health)
                }
                let networks = details.networkSettings.networks.additionalProperties
                if !networks.isEmpty {
                    networkSection(networks)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var statusHeader: some View {
        HStack(spacing: 16) {
            ZStack(alignment: .bottomTrailing) {
                CachedAsyncImage(url: container.iconUrl, size: 56) {
                    Image(systemName: "cube.box.fill")
                        .font(.title)
                        .foregroundStyle(isRunning ? .green : .secondary)
                        .frame(width: 56, height: 56)
                        .glassEffect(.regular, in: .circle)
                }
                Circle()
                    .fill(statusIndicatorColor)
                    .frame(width: 14, height: 14)
                    .offset(x: 2, y: 2)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(displayedName)
                    .font(.title3.bold())
                    .lineLimit(2)
                Text(container.image)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                StatusBadge(status: statusString)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusIndicatorColor: Color {
        switch statusString.lowercased() {
        case "running": return .green
        case "paused": return .orange
        default: return .secondary.opacity(0.5)
        }
    }

    @ViewBuilder
    private var actionsSection: some View {
        if isPaused {
            Button {
                Task { await performAction(.unpause) }
            } label: {
                Label("Unpause", systemImage: "play.circle.fill")
                    .foregroundStyle(.green)
            }
            .disabled(isActioning)

            Button(role: .destructive) {
                showKillConfirm = true
            } label: {
                Label("Kill", systemImage: "bolt.slash.fill")
                    .foregroundStyle(.red)
            }
            .disabled(isActioning)
        } else if isRunning {
            Button {
                Task { await performAction(.stop) }
            } label: {
                Label("Stop", systemImage: "stop.circle.fill")
                    .foregroundStyle(.red)
            }
            .disabled(isActioning)

            Button {
                Task { await performAction(.restart) }
            } label: {
                Label("Restart", systemImage: "arrow.clockwise.circle.fill")
                    .foregroundStyle(.orange)
            }
            .disabled(isActioning)

            Button {
                Task { await performAction(.pause) }
            } label: {
                Label("Pause", systemImage: "pause.circle.fill")
                    .foregroundStyle(.orange)
            }
            .disabled(isActioning)

            Button(role: .destructive) {
                showKillConfirm = true
            } label: {
                Label("Kill", systemImage: "bolt.slash.fill")
                    .foregroundStyle(.red)
            }
            .disabled(isActioning)
        } else {
            Button {
                Task { await performAction(.start) }
            } label: {
                Label("Start", systemImage: "play.circle.fill")
                    .foregroundStyle(.green)
            }
            .disabled(isActioning)
        }

        Button {
            Task { await performAction(.redeploy) }
        } label: {
            Label("Redeploy", systemImage: "arrow.triangle.2.circlepath.circle.fill")
                .foregroundStyle(Color.accentColor)
        }
        .disabled(isActioning)

        Button {
            showLogs = true
        } label: {
            Label("View Logs", systemImage: "doc.text.fill")
        }

        if isRunning && !isPaused {
            Button {
                showTerminal = true
            } label: {
                Label("Terminal", systemImage: "terminal.fill")
            }
        }
    }

    private func configSection(_ config: ContainerConfig) -> some View {
        Section("Configuration") {
            if let img = config.image {
                LabeledContent("Image", value: img)
            }
            if let cmd = config.cmd, !cmd.isEmpty {
                LabeledContent("Command", value: cmd.joined(separator: " "))
            }
            if let wd = config.workingDir, !wd.isEmpty {
                LabeledContent("Working Dir", value: wd)
            }
            if let user = config.user, !user.isEmpty {
                LabeledContent("User", value: user)
            }
            if let env = config.env, !env.isEmpty {
                NavigationLink("Environment (\(env.count))") {
                    EnvVarsView(vars: env)
                }
            }
            if let labels = config.labels, !labels.isEmpty {
                NavigationLink("Labels (\(labels.count))") {
                    LabelsView(labels: labels)
                }
            }
        }
    }

    private func stateSection(_ state: ContainerState) -> some View {
        Section("State") {
            LabeledContent("Status", value: state.status.capitalized)
            if let startedAt = state.startedAt {
                LabeledContent("Started", value: startedAt.formattedDate)
            }
            if !isRunning, let finishedAt = state.finishedAt {
                LabeledContent("Finished", value: finishedAt.formattedDate)
            }
            if let exitCode = state.exitCode, !isRunning {
                LabeledContent("Exit Code", value: "\(exitCode)")
            }
        }
    }

    private func hostConfigSection(_ hostConfig: ContainerHostConfig) -> some View {
        Section("Host Config") {
            if let mode = hostConfig.networkMode {
                LabeledContent("Network Mode", value: mode)
            }
            if let policy = hostConfig.restartPolicy {
                LabeledContent("Restart Policy", value: policy)
            }
            if let memory = hostConfig.memory, memory > 0 {
                LabeledContent("Memory Limit", value: memory.byteString)
            }
            if let privileged = hostConfig.privileged, privileged {
                LabeledContent("Privileged", value: "Yes")
            }
            if let binds = hostConfig.binds, !binds.isEmpty {
                NavigationLink("Mounts (\(binds.count))") {
                    BindsView(binds: binds)
                }
            }
        }
    }

    private func networkSection(_ networks: [String: ContainerNetworkEndpoint]) -> some View {
        Section("Networks") {
            ForEach(Array(networks.keys.sorted()), id: \.self) { netName in
                if let endpoint = networks[netName] {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(netName).font(.headline)
                        if let ip = endpoint.ipAddress, !ip.isEmpty {
                            Text("IP: \(ip)").font(.caption).foregroundStyle(.secondary)
                        }
                        if let mac = endpoint.macAddress, !mac.isEmpty {
                            Text("MAC: \(mac)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - Actions

    private enum ContainerAction { case start, stop, restart, pause, unpause, kill, redeploy }

    private func performAction(_ action: ContainerAction) async {
        guard let client = manager.client else { return }
        isActioning = true
        defer { isActioning = false }
        do {
            switch action {
            case .start: try await client.containers.start(envID: environmentID, id: container.id)
            case .stop: try await client.containers.stop(envID: environmentID, id: container.id)
            case .restart: try await client.containers.restart(envID: environmentID, id: container.id)
            case .pause: try await client.pauseContainer(envID: environmentID, id: container.id)
            case .unpause: try await client.unpauseContainer(envID: environmentID, id: container.id)
            case .kill: try await client.killContainer(envID: environmentID, id: container.id)
            case .redeploy:
                let path = client.rest.environmentPath(environmentID, "containers/\(container.id)/redeploy")
                let _: ContainerInfo = try await client.rest.post(path, body: String?.none)
            }
            await invalidateContainerCaches()
            await loadDetails()
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func deleteContainer() async {
        guard let client = manager.client else { return }
        isActioning = true
        defer { isActioning = false }
        do {
            let path = client.rest.environmentPath(environmentID, "containers/\(container.id)")
            let _: DataResponse<String> = try await client.rest.delete(path)
            await invalidateContainerCaches()
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func renameContainer(newName: String) async -> Result<Void, Error> {
        guard let client = manager.client else {
            return .failure(ArcaneError.transport("No client"))
        }
        do {
            try await client.renameContainer(envID: environmentID, id: container.id, newName: newName)
            await invalidateContainerCaches()
            await loadDetails()
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    private func loadDetails() async {
        guard let client = manager.client else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            details = try await client.containers.inspect(envID: environmentID, id: container.id)
        } catch {
            // Ignore inspect errors — show what we have
        }
    }

    private func invalidateContainerCaches() async {
        guard let cached = manager.cached, let client = manager.client else { return }
        await cached.invalidate(envID: environmentID, paths: [
            client.rest.environmentPath(environmentID, "containers"),
            client.rest.environmentPath(environmentID, "containers/*")
        ])
    }
}

// MARK: - Sub-views

struct EnvVarsView: View {
    let vars: [String]
    @State private var searchText = ""

    private var filtered: [String] {
        searchText.isEmpty ? vars : vars.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        List(filtered, id: \.self) { v in
            let parts = v.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                VStack(alignment: .leading) {
                    Text(String(parts[0])).font(.caption.bold()).foregroundStyle(.secondary)
                    Text(String(parts[1])).font(.body).textSelection(.enabled)
                }
            } else {
                Text(v).font(.caption).textSelection(.enabled)
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $searchText)
        .navigationTitle("Environment Variables")
    }
}

struct LabelsView: View {
    let labels: [String: String]

    var body: some View {
        List(Array(labels.keys.sorted()), id: \.self) { key in
            VStack(alignment: .leading) {
                Text(key).font(.caption.bold()).foregroundStyle(.secondary)
                Text(labels[key] ?? "").font(.body).textSelection(.enabled)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Labels")
    }
}

struct BindsView: View {
    let binds: [String]

    var body: some View {
        List(binds, id: \.self) { bind in
            Text(bind).font(.caption.monospaced()).textSelection(.enabled)
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Mounts")
    }
}

// MARK: - Helpers
private extension String {
    var formattedDate: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: self) {
            return date.formatted(date: .abbreviated, time: .shortened)
        }
        return self
    }
}
