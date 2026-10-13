import Arcane
import SwiftUI

/// Swarm hub for one environment. Shows the cluster sections when the host is
/// an active swarm member, otherwise the initialize / join setup.
struct SwarmView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutationStore
    let environmentID: EnvironmentID
    let environmentName: String

    /// nil until the first load finishes.
    @State private var isActive: Bool?
    @State private var info: SwarmInfo?
    @State private var isLoading = false
    @State private var errorMessage: String?

    init(environmentID: EnvironmentID = .localDocker, environmentName: String = "Local Docker") {
        self.environmentID = environmentID
        self.environmentName = environmentName
    }

    private var swarmVersion: Int { mutationStore.version(kind: .swarm, envID: environmentID) }

    private func can(_ permission: String) -> Bool {
        manager.permissions.has(permission, in: environmentID)
    }

    var body: some View {
        // Every branch renders a view: `.task` never runs on an empty Group.
        Group {
            if let isActive {
                if isActive {
                    hub
                } else {
                    SwarmSetupView(environmentID: environmentID, environmentName: environmentName)
                }
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Couldn't Load Swarm", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try Again") { Task { await load() } }
                }
            } else {
                ArcaneLoadingView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Swarm")
        .task(id: environmentID) { await load() }
        .onChange(of: swarmVersion) { _, _ in
            Task { await load() }
        }
    }

    private var hub: some View {
        List {
            if let info {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: "square.stack.3d.up.fill")
                            .font(.title2)
                            .foregroundStyle(.tint)
                            .frame(width: 44, height: 44)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(environmentName)
                                .font(.headline)
                            Text(verbatim: String(info.id.prefix(12)))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Text("Created \(SwarmPresentation.date(info.createdAt))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if info.rootRotationInProgress {
                        Label("Root CA rotation in progress", systemImage: "arrow.triangle.2.circlepath")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
            }
            Section("Workloads") {
                NavigationLink {
                    SwarmServicesView(environmentID: environmentID)
                } label: {
                    Label("Services", systemImage: "shippingbox.fill")
                }
                NavigationLink {
                    SwarmStacksView(environmentID: environmentID)
                } label: {
                    Label("Stacks", systemImage: "square.stack.3d.up")
                }
                NavigationLink {
                    SwarmTasksView(environmentID: environmentID, source: .all)
                } label: {
                    Label("Tasks", systemImage: "checklist")
                }
            }
            Section("Cluster") {
                NavigationLink {
                    SwarmNodesView(environmentID: environmentID)
                } label: {
                    Label("Nodes", systemImage: "server.rack")
                }
                NavigationLink {
                    SwarmKeyValueListView(kind: .config, environmentID: environmentID)
                } label: {
                    Label("Configs", systemImage: "doc.text")
                }
                NavigationLink {
                    SwarmKeyValueListView(kind: .secret, environmentID: environmentID)
                } label: {
                    Label("Secrets", systemImage: "key.fill")
                }
                NavigationLink {
                    SwarmClusterView(environmentID: environmentID)
                } label: {
                    Label("Cluster", systemImage: "point.3.connected.trianglepath.dotted")
                }
            }
        }
        .listStyle(.insetGrouped)
        .softTopScrollEdgeEffectCompat()
        .refreshable { await load() }
    }

    private func load() async {
        guard let client = manager.client, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        // The server's `status` is a stored flag refreshed on sync, so it can lag
        // right after an init or join; cluster info succeeding is authoritative.
        let info = try? await client.swarm.info(envID: environmentID)
        if let info {
            self.info = info
            isActive = true
            errorMessage = nil
            return
        }
        do {
            isActive = try await client.swarm.status(envID: environmentID).enabled
            self.info = nil
            errorMessage = nil
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }
}
