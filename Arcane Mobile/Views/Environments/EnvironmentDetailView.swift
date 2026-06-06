import SwiftUI
import Arcane

struct EnvironmentDetailView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    let environment: Arcane.Environment

    @State private var dockerInfo: DockerInfo?
    @State private var isLoading = false
    @State private var isTestingConnection = false

    private var envID: EnvironmentID { EnvironmentID(rawValue: environment.id) }

    var body: some View {
        List {
            // Arcane.Environment info header
            Section {
                infoCard
            }

            // Resource navigation
            Section("Resources") {
                resourceLink(
                    title: "Containers",
                    icon: "cube.box.fill",
                    color: Color.accentColor,
                    destination: ContainersView(environmentID: envID, environmentName: environment.name ?? environment.id)
                )
                resourceLink(
                    title: "Images",
                    icon: "photo.stack.fill",
                    color: Color.accentColor,
                    destination: ImagesView(environmentID: envID, environmentName: environment.name ?? environment.id)
                )
                resourceLink(
                    title: "Volumes",
                    icon: "externaldrive.fill",
                    color: Color.accentColor,
                    destination: VolumesView(environmentID: envID, environmentName: environment.name ?? environment.id)
                )
                resourceLink(
                    title: "Networks",
                    icon: "network",
                    color: Color.accentColor,
                    destination: NetworksView(environmentID: envID, environmentName: environment.name ?? environment.id)
                )
                resourceLink(
                    title: "Projects",
                    icon: "square.stack.3d.up.fill",
                    color: Color.accentColor,
                    destination: ProjectsView(environmentID: envID, environmentName: environment.name ?? environment.id)
                )
            }

            // System info
            if let info = dockerInfo {
                Section("Docker Info") {
                    LabeledContent("Docker Version", value: info.serverVersion ?? "—")
                    LabeledContent("OS", value: info.operatingSystem ?? "—")
                    LabeledContent("Architecture", value: info.architecture)
                    LabeledContent("CPUs", value: info.ncpu.map { "\($0)" } ?? "—")
                    LabeledContent("Memory", value: info.memTotal?.byteString ?? "—")
                    if let swarmState = info.info?["Swarm"]?.objectValue?["LocalNodeState"]?.stringValue,
                       swarmState != "inactive" {
                        LabeledContent("Swarm", value: swarmState.capitalized)
                    }
                }
            }

        }
        .listStyle(.insetGrouped)
        .softTopScrollEdgeEffectCompat()
        .morphingActions(
            primary: ActionButtonItem(
                id: "test",
                title: "Test Connection",
                systemImage: "network",
                tint: .accentColor
            ) {
                Task { await testConnection() }
            },
            runningItemID: isTestingConnection ? "test" : nil,
            isDisabled: isTestingConnection
        )
        .navigationTitle(environment.name ?? environment.id)
        .navigationBarTitleDisplayMode(.large)
        .task { await loadDockerInfo() }
        .refreshable { await loadDockerInfo(refresh: true) }
    }

    private var infoCard: some View {
        HStack(spacing: 16) {
            Image(systemName: "server.rack")
                .font(.title)
                .foregroundStyle(environment.isOnline ?? false ? .green : .secondary)
                .frame(width: 56, height: 56)
                .glassEffectCompat(in: .circle)

            VStack(alignment: .leading, spacing: 4) {
                Text(environment.name ?? environment.id)
                    .font(.title3.bold())
                if !environment.apiUrl.isEmpty {
                    Text(environment.apiUrl)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                StatusBadge(status: environment.status)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func resourceLink<Dest: View>(title: String, icon: String, color: Color, destination: Dest) -> some View {
        NavigationLink(destination: destination) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: icon)
                    .foregroundStyle(color)
            }
        }
    }

    private func loadDockerInfo(refresh: Bool = false) async {
        guard let client = manager.client, let cached = manager.cached else { return }
        if dockerInfo == nil { isLoading = true }
        defer { isLoading = false }
        let path = client.rest.environmentPath(envID, "system/docker/info")
        let fetcher: @Sendable () async throws -> DockerInfo = {
            let rawData = try await client.transport.rawRequest(path, body: Optional<String>.none)
            return try JSONDecoder().decode(DockerInfo.self, from: rawData)
        }
        if let result = try? await cached.getCustom(
            path: path, as: DockerInfo.self, policy: .dockerInfo,
            envID: envID, refresh: refresh,
            onFresh: { fresh in dockerInfo = fresh },
            fetcher: fetcher
        ) {
            dockerInfo = result
        }
    }

    private func testConnection() async {
        guard let client = manager.client else { return }
        isTestingConnection = true
        defer { isTestingConnection = false }
        do {
            let path = client.rest.environmentPath(envID, "test")
            let _: DataResponse<String> = try await client.rest.post(path, body: String?.none)
        } catch {
            // Handle error
        }
    }
}
