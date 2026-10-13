import Arcane
import SwiftUI

/// Cluster identity, join tokens, unlock, and leave for an active swarm.
struct SwarmClusterView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutationStore
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let environmentID: EnvironmentID

    @State private var info: SwarmInfo?
    @State private var tokens: SwarmJoinTokens?
    @State private var unlockKey: String?
    @State private var revealed: Set<String> = []
    @State private var errorMessage: String?
    @State private var pendingRotation: TokenRole?
    @State private var showLeave = false
    @State private var showUnlock = false
    @State private var unlockInput = ""
    @State private var isWorking = false

    private enum TokenRole: String, Identifiable {
        case worker, manager
        var id: String { rawValue }
    }

    private func can(_ permission: String) -> Bool {
        manager.permissions.has(permission, in: environmentID)
    }

    var body: some View {
        List {
            if let info {
                Section("Cluster") {
                    copyRow("ID", value: info.id)
                    LabeledContent("Created", value: SwarmPresentation.date(info.createdAt))
                    LabeledContent("Updated", value: SwarmPresentation.date(info.updatedAt))
                    if info.rootRotationInProgress {
                        Label("Root CA rotation in progress", systemImage: "arrow.triangle.2.circlepath")
                            .foregroundStyle(.orange)
                    }
                }
            }
            if can(Permission.Swarm.unlock) {
                Section {
                    if let tokens {
                        tokenRow("Worker", token: tokens.worker)
                        tokenRow("Manager", token: tokens.manager)
                        Menu {
                            Button("Rotate Worker Token") { pendingRotation = .worker }
                            Button("Rotate Manager Token") { pendingRotation = .manager }
                        } label: {
                            Label("Rotate Tokens", systemImage: "arrow.triangle.2.circlepath")
                        }
                    } else {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                } header: {
                    Text("Join Tokens")
                } footer: {
                    Text("Use with docker swarm join on the node you want to add.")
                }
                Section {
                    if let unlockKey {
                        if unlockKey.isEmpty {
                            Text("Autolock is off, so there's no unlock key.")
                                .foregroundStyle(.secondary)
                        } else {
                            tokenRow("Unlock Key", token: unlockKey)
                        }
                    } else {
                        Button {
                            Task { await loadUnlockKey() }
                        } label: {
                            Label("Show Unlock Key", systemImage: "key")
                        }
                    }
                    Button {
                        unlockInput = ""
                        showUnlock = true
                    } label: {
                        Label("Unlock Swarm", systemImage: "lock.open")
                    }
                } header: {
                    Text("Autolock")
                }
            }
            if can(Permission.Swarm.leave) {
                Section {
                    Button(role: .destructive) {
                        showLeave = true
                    } label: {
                        DestructiveLabel(text: "Leave Swarm", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .disabled(isWorking)
                } footer: {
                    Text("This environment's Docker host leaves the swarm.")
                }
            }
            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
        }
        .listStyle(.insetGrouped)
        .softTopScrollEdgeEffectCompat()
        .navigationTitle("Cluster")
        .task { await load() }
        .refreshable { await load() }
        .deleteConfirmation(item: $pendingRotation) { role in
            DeleteConfirmationConfig(
                title: "Rotate \(role.rawValue.capitalized) Token",
                message:
                    "The current \(role.rawValue) token stops working. Nodes already in the swarm aren't affected.",
                icon: "arrow.triangle.2.circlepath",
                actions: [
                    DeleteConfirmationAction(title: "Rotate") {
                        Task { await rotate(role) }
                    }
                ]
            )
        }
        .deleteConfirmation(
            isPresented: $showLeave,
            config: DeleteConfirmationConfig(
                title: "Leave Swarm",
                message: "A manager must be forced to leave, which can break quorum for the rest of the cluster.",
                icon: "rectangle.portrait.and.arrow.right",
                actions: [
                    DeleteConfirmationAction(title: "Leave") { Task { await leave(force: false) } },
                    DeleteConfirmationAction(title: "Force Leave") { Task { await leave(force: true) } },
                ]
            )
        )
        .alert("Unlock Swarm", isPresented: $showUnlock) {
            SecureField("Unlock key", text: $unlockInput)
            Button("Unlock") { Task { await unlock() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter the key shown when autolock was enabled.")
        }
    }

    private func copyRow(_ title: String, value: String) -> some View {
        LabeledContent(title) {
            Button {
                UIPasteboard.general.string = value
                showToast(.copied())
            } label: {
                HStack(spacing: 6) {
                    MonospacedValue(value: String(value.prefix(12)))
                    Image(systemName: "doc.on.doc").font(.caption)
                }
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Copy \(title)")
        }
    }

    private func tokenRow(_ title: String, token: String) -> some View {
        let isRevealed = revealed.contains(title)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    if isRevealed { revealed.remove(title) } else { revealed.insert(title) }
                } label: {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(isRevealed ? "Hide \(title)" : "Reveal \(title)")
                Button {
                    UIPasteboard.general.string = token
                    showToast(.copied())
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Copy \(title)")
            }
            Text(verbatim: isRevealed ? token : String(repeating: "•", count: 24))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(isRevealed ? nil : 1)
        }
    }

    private func load() async {
        guard let client = manager.client else { return }
        do {
            info = try await client.swarm.info(envID: environmentID)
            if can(Permission.Swarm.unlock) {
                tokens = try await client.swarm.joinTokens(envID: environmentID)
            }
            errorMessage = nil
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func loadUnlockKey() async {
        guard let client = manager.client else { return }
        do {
            unlockKey = try await client.swarm.unlockKey(envID: environmentID).unlockKey
            revealed.insert("Unlock Key")
        } catch {
            showToast(.error(friendlyErrorMessage(error)))
        }
    }

    private func rotate(_ role: TokenRole) async {
        guard let client = manager.client else { return }
        do {
            try await client.swarm.rotateJoinTokens(
                SwarmRotateJoinTokensRequest(
                    rotateWorkerToken: role == .worker, rotateManagerToken: role == .manager),
                envID: environmentID
            )
            tokens = try await client.swarm.joinTokens(envID: environmentID)
            showToast(.success("\(role.rawValue.capitalized) token rotated"))
        } catch {
            showToast(.error(friendlyErrorMessage(error)))
        }
    }

    private func unlock() async {
        guard let client = manager.client else { return }
        let key = unlockInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try await client.swarm.unlock(key: key, envID: environmentID)
            await manager.swarmChanged(environmentID, mutationStore: mutationStore)
            showToast(.success("Swarm unlocked"))
        } catch {
            showToast(.error(friendlyErrorMessage(error)))
        }
    }

    private func leave(force: Bool) async {
        guard let client = manager.client else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await client.swarm.leave(force: force, envID: environmentID)
            await manager.swarmChanged(environmentID, mutationStore: mutationStore)
            showToast(.success("Left the swarm"))
            dismiss()
        } catch {
            showToast(.error(friendlyErrorMessage(error)))
        }
    }
}

/// Shown when the environment's Docker host isn't in a swarm.
struct SwarmSetupView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutationStore
    let environmentID: EnvironmentID
    let environmentName: String

    @State private var listenAddress = ""
    @State private var advertiseAddress = ""
    @State private var autoLock = false
    @State private var forceNewCluster = false
    @State private var joinAddresses = ""
    @State private var joinToken = ""
    @State private var joinListenAddress = ""
    @State private var joinAdvertiseAddress = ""
    @State private var runningAction: String?
    @State private var errorMessage: String?

    private func can(_ permission: String) -> Bool {
        manager.permissions.has(permission, in: environmentID)
    }

    private var remoteAddresses: [String] {
        joinAddresses.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Not in a Swarm", systemImage: "square.stack.3d.up.slash")
                        .font(.headline)
                    Text(
                        "\(environmentName) isn't part of a Docker swarm. Initialize a new swarm or join an existing one."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            if can(Permission.Swarm.initialize) {
                Section {
                    FormTextField(
                        title: "Listen Address", placeholder: "0.0.0.0:2377", text: $listenAddress,
                        autocapitalization: .never, autocorrectionDisabled: true)
                    FormTextField(
                        title: "Advertise Address", placeholder: "Automatic", text: $advertiseAddress,
                        autocapitalization: .never, autocorrectionDisabled: true)
                    Toggle("Autolock Managers", isOn: $autoLock)
                    Toggle("Force New Cluster", isOn: $forceNewCluster)
                    actionButton("Initialize Swarm", id: "init", systemImage: "plus.circle") {
                        await initialize()
                    }
                } header: {
                    Text("Initialize")
                } footer: {
                    Text("This host becomes the first manager of a new swarm.")
                }
            }
            if can(Permission.Swarm.join) {
                Section {
                    FormTextField(
                        title: "Manager Addresses", placeholder: "10.0.0.1:2377", text: $joinAddresses,
                        autocapitalization: .never, autocorrectionDisabled: true,
                        helper: "Comma-separated.")
                    FormSecureField(title: "Join Token", placeholder: "SWMTKN-…", text: $joinToken)
                    FormTextField(
                        title: "Listen Address", placeholder: "0.0.0.0:2377", text: $joinListenAddress,
                        autocapitalization: .never, autocorrectionDisabled: true)
                    FormTextField(
                        title: "Advertise Address", placeholder: "Automatic", text: $joinAdvertiseAddress,
                        autocapitalization: .never, autocorrectionDisabled: true)
                    actionButton("Join Swarm", id: "join", systemImage: "person.badge.plus") {
                        await join()
                    }
                    .disabled(remoteAddresses.isEmpty || joinToken.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: {
                    Text("Join")
                }
            }
            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }
        }
        .disabled(runningAction != nil)
    }

    private func actionButton(
        _ title: String, id: String, systemImage: String, action: @escaping () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            HStack {
                Label(title, systemImage: systemImage)
                if runningAction == id {
                    Spacer()
                    ProgressView().controlSize(.small)
                }
            }
        }
    }

    private func optional(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func initialize() async {
        guard let client = manager.client else { return }
        runningAction = "init"
        errorMessage = nil
        defer { runningAction = nil }
        do {
            _ = try await client.swarm.initSwarm(
                SwarmInitRequest(
                    listenAddr: optional(listenAddress),
                    advertiseAddr: optional(advertiseAddress),
                    forceNewCluster: forceNewCluster ? true : nil,
                    spec: .object([:]),
                    autoLockManagers: autoLock ? true : nil
                ),
                envID: environmentID
            )
            await manager.swarmChanged(environmentID, mutationStore: mutationStore)
            showToast(.success("Swarm initialized"))
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func join() async {
        guard let client = manager.client else { return }
        runningAction = "join"
        errorMessage = nil
        defer { runningAction = nil }
        do {
            try await client.swarm.join(
                SwarmJoinRequest(
                    listenAddr: optional(joinListenAddress),
                    advertiseAddr: optional(joinAdvertiseAddress),
                    remoteAddrs: remoteAddresses,
                    joinToken: joinToken.trimmingCharacters(in: .whitespacesAndNewlines)
                ),
                envID: environmentID
            )
            await manager.swarmChanged(environmentID, mutationStore: mutationStore)
            showToast(.success("Joined the swarm"))
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }
}
