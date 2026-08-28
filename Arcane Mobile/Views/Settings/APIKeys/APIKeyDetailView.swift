import SwiftUI
import Arcane

struct APIKeyDetailView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.dismiss) private var dismiss

    let assignedUser: User?
    let onChanged: () async -> Void

    @State private var apiKey: APIKey
    @State private var metadata: APIKeyServerMetadata?
    @State private var metadataLoaded = false
    @State private var showEditSheet = false
    @State private var showRotateConfirmation = false
    @State private var revealedKey: APIKeySecretPresentation?
    @State private var runningActionID: String?
    @State private var refreshAfterReveal = false
    @State private var dismissAfterReveal = false

    init(
        apiKey: APIKey,
        assignedUser: User?,
        onChanged: @escaping () async -> Void
    ) {
        self.assignedUser = assignedUser
        self.onChanged = onChanged
        _apiKey = State(initialValue: apiKey)
    }

    private var supportsRBAC: Bool {
        manager.serverCapabilities?.supportsRoleManagement == true
    }

    private var isProtected: Bool {
        apiKey.isStatic || metadata?.isBootstrap == true
    }

    private var isExpired: Bool {
        apiKey.expiresAt.map { $0 <= Date() } == true
    }

    private var canUpdate: Bool {
        if !supportsRBAC { return manager.currentUser?.isAdmin == true }
        return manager.permissions.has(Permission.ApiKeys.update, in: nil)
    }

    private var canCreate: Bool {
        if !supportsRBAC { return manager.currentUser?.isAdmin == true }
        return manager.permissions.has(Permission.ApiKeys.create, in: nil)
    }

    private var canDelete: Bool {
        if !supportsRBAC { return manager.currentUser?.isAdmin == true }
        return manager.permissions.has(Permission.ApiKeys.delete, in: nil)
    }

    private var kindLabel: String {
        if apiKey.isStatic { return "Static" }
        if metadata?.isBootstrap == true { return "Environment" }
        if metadata?.kind == "personal" { return "Personal" }
        if supportsRBAC { return "Scoped" }
        return "Standard"
    }

    private var rotationUnavailableReason: String? {
        if isProtected { return "Environment-managed keys cannot be rotated here." }
        guard apiKey.userId == manager.currentUser?.id else {
            return "Only the assigned user can rotate this key without changing its ownership."
        }
        guard canCreate && canDelete else {
            return "Creating and deleting API keys are both required to rotate this key."
        }
        if supportsRBAC {
            guard metadataLoaded else { return "Loading key access…" }
            guard let metadata else {
                return "This key's access could not be loaded, so it cannot be rotated safely."
            }
            if metadata.kind != "personal", metadata.permissions?.isEmpty != false {
                return "This key has no reusable permission grants, so it cannot be rotated safely."
            }
        }
        return nil
    }

    private var actionItems: [ActionButtonItem] {
        var items: [ActionButtonItem] = []
        if canUpdate && !isProtected {
            items.append(ActionButtonItem(
                id: "edit",
                title: "Edit",
                systemImage: "pencil",
                tint: .blue
            ) {
                showEditSheet = true
            })
        }
        if rotationUnavailableReason == nil {
            items.append(ActionButtonItem(
                id: "rotate",
                title: "Rotate",
                systemImage: "arrow.triangle.2.circlepath",
                tint: .orange
            ) {
                showRotateConfirmation = true
            })
        }
        if canDelete && !isProtected {
            items.append(ActionButtonItem(
                id: "delete",
                title: "Delete",
                systemImage: "trash",
                tint: .red,
                role: .destructive,
                confirmationMessage: "This permanently revokes the API key. Anything using it will stop working."
            ) {
                Task { await deleteKey() }
            })
        }
        return items
    }

    var body: some View {
        Form {
            identitySection
            keySection
            detailsSection

            if let description = apiKey.description, !description.isEmpty {
                Section("Description") {
                    Text(description)
                }
            }

            if isProtected {
                Section {
                    protectedNotice
                }
            } else if let reason = rotationUnavailableReason,
                      reason != "Loading key access…" {
                Section {
                    rotationNotice(reason)
                }
            }
        }
        .navigationTitle("API Key")
        .navigationBarTitleDisplayMode(.inline)
        .actionToolbar(
            items: actionItems,
            runningItemID: runningActionID,
            resourceName: apiKey.name
        )
        .deleteConfirmation(
            isPresented: $showRotateConfirmation,
            config: DeleteConfirmationConfig(
                title: "Rotate \(apiKey.name)?",
                message: "A replacement with the same access will be created before this key is revoked. Anything using \(apiKey.keyPrefix)… must be updated with the new key.",
                icon: "arrow.triangle.2.circlepath",
                actions: [
                    DeleteConfirmationAction(title: "Rotate", role: nil, tint: .orange) {
                        Task { await rotateKey() }
                    }
                ]
            )
        )
        .sheet(isPresented: $showEditSheet) {
            EditAPIKeyView(apiKey: apiKey, metadata: metadata) { updated in
                apiKey = updated
                await invalidateAPIKeyCache()
                await loadMetadata()
                await onChanged()
            }
        }
        .sheet(item: $revealedKey, onDismiss: finishSecretPresentation) { presentation in
            NewAPIKeyView(presentation: presentation)
        }
        .task { await loadMetadata() }
    }

    private var identitySection: some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: "key.fill")
                    .font(.largeTitle)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.yellow)
                    .frame(width: 48)

                VStack(alignment: .leading, spacing: 5) {
                    Text(apiKey.name)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        APIKeyStatusBadge(isExpired: isExpired)
                        Text(kindLabel)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.12), in: .capsule)
                    }
                }

                Spacer(minLength: 0)
            }
        }
    }

    private var keySection: some View {
        Section("Key") {
            Button {
                UIPasteboard.general.string = apiKey.keyPrefix
                showToast(.copied("Key prefix copied"))
            } label: {
                LabeledContent("Prefix") {
                    HStack(spacing: 8) {
                        Text(verbatim: apiKey.keyPrefix)
                            .font(.body.monospaced())
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Image(systemName: "doc.on.doc")
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Key prefix \(apiKey.keyPrefix), copy")
        }
    }

    private var detailsSection: some View {
        Section("Details") {
            detailRow(
                "Assigned To",
                value: APIKeyOwnerText.detail(user: assignedUser, userID: apiKey.userId)
            )
            detailRow(
                "Created",
                value: apiKey.createdAt.formatted(date: .abbreviated, time: .shortened)
            )
            detailRow(
                "Last Used",
                value: apiKey.lastUsedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Never"
            )
            detailRow(
                "Expiration",
                value: apiKey.expiresAt?.formatted(date: .abbreviated, time: .shortened) ?? "Never",
                tint: isExpired ? .red : .secondary
            )
            if supportsRBAC, let permissions = metadata?.permissions {
                detailRow(
                    "Permissions",
                    value: "\(String(permissions.count)) \(metadata?.kind == "personal" ? "inherited" : "granted")"
                )
            }
            if let updatedAt = apiKey.updatedAt {
                detailRow(
                    "Updated",
                    value: updatedAt.formatted(date: .abbreviated, time: .shortened)
                )
            }
        }
    }

    private func detailRow(_ label: String, value: String, tint: Color = .secondary) -> some View {
        LabeledContent(label) {
            Text(value)
                .foregroundStyle(tint)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var protectedNotice: some View {
        Label {
            Text(apiKey.isStatic
                 ? "This static key is managed by Arcane and cannot be edited, rotated, or deleted."
                 : "This key is paired with an environment and cannot be edited, rotated, or deleted.")
        } icon: {
            Image(systemName: "lock.fill")
                .foregroundStyle(.orange)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func rotationNotice(_ reason: String) -> some View {
        Label(reason, systemImage: "info.circle.fill")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func loadMetadata() async {
        guard let client = manager.client else {
            metadataLoaded = true
            return
        }
        defer { metadataLoaded = true }
        let path = "api-keys/\(ArcaneAPIHelpers.escapedPathComponent(apiKey.id))"
        metadata = try? await client.rest.get(path)
    }

    private func deleteKey() async {
        guard let client = manager.client else { return }
        runningActionID = "delete"
        defer { runningActionID = nil }
        do {
            try await client.apiKeys.delete(id: apiKey.id)
            await invalidateAPIKeyCache()
            showToast(.success("API key deleted"))
            dismiss()
            await onChanged()
        } catch {
            showToast(.error(friendlyErrorMessage(error)))
        }
    }

    private func rotateKey() async {
        guard rotationUnavailableReason == nil, let client = manager.client else { return }
        runningActionID = "rotate"
        defer { runningActionID = nil }

        let isPersonal = supportsRBAC && metadata?.kind == "personal"
        let permissions = supportsRBAC && !isPersonal ? metadata?.permissions : nil
        let body = APIKeyMutationRequest(
            name: apiKey.name,
            description: apiKey.description,
            expiresAt: apiKey.expiresAt,
            permissions: permissions
        )

        do {
            let created: APIKeyCreated
            if isPersonal {
                created = try await client.rest.post("auth/me/api-keys", body: body)
            } else {
                created = try await client.rest.post("api-keys", body: body)
            }

            var oldKeyRevoked = true
            do {
                if isPersonal {
                    let path = "auth/me/api-keys/\(ArcaneAPIHelpers.escapedPathComponent(apiKey.id))"
                    try await client.rest.deleteVoid(path)
                } else {
                    try await client.apiKeys.delete(id: apiKey.id)
                }
            } catch {
                oldKeyRevoked = false
            }

            refreshAfterReveal = true
            dismissAfterReveal = oldKeyRevoked
            revealedKey = .rotated(created.key, oldKeyRevoked: oldKeyRevoked)
        } catch {
            showToast(.error(friendlyErrorMessage(error)))
        }
    }

    private func finishSecretPresentation() {
        guard refreshAfterReveal else { return }
        let shouldDismiss = dismissAfterReveal
        refreshAfterReveal = false
        dismissAfterReveal = false
        Task {
            await invalidateAPIKeyCache()
            if shouldDismiss { dismiss() }
            await onChanged()
            if shouldDismiss {
                showToast(.success("API key rotated"))
            }
        }
    }

    private func invalidateAPIKeyCache() async {
        if let cached = manager.cached {
            await cached.invalidateGlobal(paths: ["api-keys", "api-keys/*"])
        }
    }
}
