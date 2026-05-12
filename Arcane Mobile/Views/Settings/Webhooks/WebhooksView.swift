import SwiftUI
import Arcane

struct WebhooksView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @State private var webhooks: [WebhookSummary] = []
    @State private var isLoading = false
    @State private var showCreateSheet = false
    @State private var createdWebhook: CreatedWebhookWrapper?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading && webhooks.isEmpty {
                ProgressView("Loading webhooks…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if webhooks.isEmpty {
                ContentUnavailableView("No Webhooks", systemImage: "link.badge.plus", description: Text("Create a webhook to trigger actions via HTTP."))
            } else {
                List {
                    ForEach(webhooks) { webhook in
                        WebhookRow(webhook: webhook)
                            .contextMenu {
                                Button {
                                    Task { await toggleWebhook(webhook) }
                                } label: {
                                    Label(
                                        webhook.enabled ? "Disable" : "Enable",
                                        systemImage: webhook.enabled ? "pause.circle" : "play.circle"
                                    )
                                }
                                Button(role: .destructive) {
                                    Task { await deleteWebhook(webhook) }
                                } label: {
                                    DestructiveLabel(text: "Delete")
                                }
                                .tint(.red)
                            } preview: {
                                webhookPreview(webhook)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    Task { await deleteWebhook(webhook) }
                                } label: {
                                    DestructiveLabel(text: "Delete")
                                }
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    Task { await toggleWebhook(webhook) }
                                } label: {
                                    Label(
                                        webhook.enabled ? "Disable" : "Enable",
                                        systemImage: webhook.enabled ? "pause.circle" : "play.circle"
                                    )
                                }
                                .tint(webhook.enabled ? .orange : .green)
                            }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Webhooks")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showCreateSheet = true } label: { Image(systemName: "plus") }
            }
        }
        .task { await loadWebhooks() }
        .refreshable { await loadWebhooks(refresh: true) }
        .sheet(isPresented: $showCreateSheet) {
            CreateWebhookView { created in
                createdWebhook = .init(token: created.token, name: created.name)
                Task { await loadWebhooks() }
            }
        }
        .sheet(item: $createdWebhook) { wrapper in
            NewWebhookTokenView(name: wrapper.name, token: wrapper.token)
        }
        .alert("Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - API

    private func loadWebhooks(refresh: Bool = false) async {
        guard let client = manager.client, let cached = manager.cached else { return }
        if webhooks.isEmpty { isLoading = true }
        defer { isLoading = false }
        do {
            let path = client.rest.environmentPath(manager.activeEnvironmentID, "webhooks")
            if let result: [WebhookSummary] = try await cached.getList(
                path, elementType: WebhookSummary.self, policy: .webhooks,
                envID: manager.activeEnvironmentID, refresh: refresh,
                onFresh: { fresh in webhooks = fresh }
            ) {
                webhooks = result
            }
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func deleteWebhook(_ webhook: WebhookSummary) async {
        guard let client = manager.client else { return }
        do {
            let path = client.rest.environmentPath(manager.activeEnvironmentID, "webhooks/\(webhook.id)")
            let _: DataResponse<String> = try await client.rest.delete(path)
            webhooks.removeAll { $0.id == webhook.id }
            await invalidateWebhookCaches()
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func toggleWebhook(_ webhook: WebhookSummary) async {
        guard let client = manager.client else { return }
        do {
            let body = WebhookUpdateInput(enabled: !webhook.enabled)
            let path = client.rest.environmentPath(manager.activeEnvironmentID, "webhooks/\(webhook.id)")
            let _: WebhookSummary = try await client.rest.put(path, body: body)
            await invalidateWebhookCaches()
            await loadWebhooks(refresh: true)
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func invalidateWebhookCaches() async {
        guard let cached = manager.cached, let client = manager.client else { return }
        await cached.invalidate(envID: manager.activeEnvironmentID, paths: [
            client.rest.environmentPath(manager.activeEnvironmentID, "webhooks") + "*"
        ])
    }

    private func webhookPreview(_ webhook: WebhookSummary) -> some View {
        var details: [RowPreviewCard.PreviewDetail] = [
            .init(icon: "arrow.right.circle", label: "Action", value: webhook.actionType.capitalized),
            .init(icon: "key", label: "Token", value: webhook.tokenPrefix + "…")
        ]
        if let targetName = webhook.targetName, !targetName.isEmpty {
            details.insert(.init(icon: "scope", label: "Target", value: targetName), at: 0)
        }
        return RowPreviewCard(
            icon: webhookIcon(for: webhook.targetType),
            iconColor: .accentColor,
            title: webhook.name,
            badges: [
                .init(text: webhook.enabled ? "Enabled" : "Disabled",
                      color: webhook.enabled ? .green : .secondary),
                .init(text: webhook.targetType.capitalized, color: .accentColor)
            ],
            details: details
        )
    }

    private func webhookIcon(for targetType: String) -> String {
        switch targetType {
        case "container": return "shippingbox"
        case "project": return "folder"
        case "updater": return "arrow.triangle.2.circlepath"
        case "gitops": return "arrow.triangle.branch"
        default: return "link"
        }
    }
}

// MARK: - Supporting Types

private struct CreatedWebhookWrapper: Identifiable {
    let id = UUID()
    let token: String
    let name: String
}

// MARK: - Webhook Row

struct WebhookRow: View {
    let webhook: WebhookSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(webhook.name).font(.headline)
                Spacer()
                Text(webhook.enabled ? "Enabled" : "Disabled")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(webhook.enabled ? Color.green.opacity(0.15) : Color.secondary.opacity(0.15))
                    .foregroundStyle(webhook.enabled ? .green : .secondary)
                    .clipShape(Capsule())
            }
            HStack(spacing: 8) {
                Label(webhook.targetType.capitalized, systemImage: targetIcon(webhook.targetType))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label(webhook.actionType.capitalized, systemImage: "arrow.right.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let targetName = webhook.targetName, !targetName.isEmpty {
                Text(targetName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            HStack {
                Text(webhook.tokenPrefix + "…")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                Spacer()
                if let triggered = webhook.lastTriggeredAt {
                    Text("Last: \(triggered, style: .relative) ago")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func targetIcon(_ type: String) -> String {
        switch type {
        case "container": return "shippingbox"
        case "project": return "folder"
        case "updater": return "arrow.triangle.2.circlepath"
        case "gitops": return "arrow.triangle.branch"
        default: return "link"
        }
    }
}

// MARK: - Token Reveal

struct NewWebhookTokenView: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let name: String
    let token: String

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "link.badge.plus")
                    .font(.system(size: 48))
                    .foregroundStyle(.green)
                    .padding(24)
                    .glassEffect(.regular, in: .circle)

                Text("Save Your Webhook Token")
                    .font(.title2.bold())

                Text("This token will only be shown once. Make sure to save it somewhere safe.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 32)

                VStack(alignment: .leading, spacing: 4) {
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(token)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                .padding(16)
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
                .padding(.horizontal, 24)

                Button {
                    UIPasteboard.general.string = token
                } label: {
                    Label("Copy to Clipboard", systemImage: "doc.on.clipboard")
                        .frame(maxWidth: .infinity)
                        .padding()
                }
                .buttonStyle(.glassProminent)
                .padding(.horizontal, 24)

                Spacer()
            }
            .padding(.top, 32)
            .navigationTitle("Webhook Created")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Create Webhook

struct CreateWebhookView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let onCreated: (WebhookCreated) -> Void

    @State private var name = ""
    @State private var targetType: WebhookCreateInput.TargetTypePayload = .container
    @State private var actionType: WebhookCreateInput.ActionTypePayload = .update
    @State private var targetId = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    // For target pickers
    @State private var containers: [ContainerInfo] = []
    @State private var projects: [Project] = []
    @State private var loadingTargets = false

    private var actionsForTarget: [WebhookCreateInput.ActionTypePayload] {
        switch targetType {
        case .container: return [.update, .start, .stop, .restart, .redeploy]
        case .project: return [.update, .up, .down, .restart, .redeploy]
        case .updater: return [.run]
        case .gitops: return [.sync]
        }
    }

    private var needsTargetId: Bool {
        targetType != .updater
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Webhook Details") {
                    TextField("Name", text: $name)
                }

                Section("Target") {
                    Picker("Target Type", selection: $targetType) {
                        Text("Container").tag(WebhookCreateInput.TargetTypePayload.container)
                        Text("Project").tag(WebhookCreateInput.TargetTypePayload.project)
                        Text("Updater").tag(WebhookCreateInput.TargetTypePayload.updater)
                        Text("GitOps").tag(WebhookCreateInput.TargetTypePayload.gitops)
                    }

                    Picker("Action", selection: $actionType) {
                        ForEach(actionsForTarget, id: \.rawValue) { action in
                            Text(action.rawValue.capitalized).tag(action)
                        }
                    }

                    if needsTargetId {
                        targetPicker
                    }
                }

                if let error = errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Create Webhook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await createWebhook() } }
                        .disabled(name.isEmpty || isLoading || (needsTargetId && targetId.isEmpty))
                }
            }
            .onChange(of: targetType) { _, _ in
                actionType = actionsForTarget.first ?? .update
                targetId = ""
            }
            .task { await loadTargets() }
        }
    }

    @ViewBuilder
    private var targetPicker: some View {
        if loadingTargets {
            HStack {
                Text("Loading targets…")
                    .foregroundStyle(.secondary)
                Spacer()
                ProgressView().scaleEffect(0.7)
            }
        } else {
            switch targetType {
            case .container:
                Picker("Container", selection: $targetId) {
                    Text("Select…").tag("")
                    ForEach(containers) { container in
                        Text(container.displayName).tag(container.id)
                    }
                }
            case .project:
                Picker("Project", selection: $targetId) {
                    Text("Select…").tag("")
                    ForEach(projects) { project in
                        Text(project.displayName).tag(project.id)
                    }
                }
            case .gitops:
                TextField("Stack ID", text: $targetId)
                    .autocapitalization(.none)
            default:
                EmptyView()
            }
        }
    }

    private func loadTargets() async {
        guard let client = manager.client else { return }
        loadingTargets = true
        defer { loadingTargets = false }
        do {
            let containerPath = client.rest.environmentPath(manager.activeEnvironmentID, "containers")
            let projectPath = client.rest.environmentPath(manager.activeEnvironmentID, "projects")
            async let c: [ContainerInfo] = client.rest.get(containerPath)
            async let p: [Project] = client.rest.get(projectPath)
            containers = (try? await c) ?? []
            projects = (try? await p) ?? []
        }
    }

    private func createWebhook() async {
        guard let client = manager.client else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let body = WebhookCreateInput(
                actionType: actionType,
                name: name,
                targetId: needsTargetId ? targetId : "",
                targetType: targetType
            )
            let path = client.rest.environmentPath(manager.activeEnvironmentID, "webhooks")
            let created: WebhookCreated = try await client.rest.post(path, body: body)
            onCreated(created)
            dismiss()
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }
}
