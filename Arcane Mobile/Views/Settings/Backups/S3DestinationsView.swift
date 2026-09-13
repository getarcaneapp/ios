import SwiftUI
import Arcane

struct S3DestinationsView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @State private var loadedIdentity = ""
    @State private var loadingIdentity: String?
    @State private var requestID = UUID()
    @State private var loadMoreError: String?
    private var listIdentity: String { "\(manager.clientGeneration)" }
    @State private var destinations: [S3Destination] = []
    @State private var errorMessage: String?
    @State private var deleteTarget: S3Destination?
    @State private var creating = false
    @State private var hasMore = false
    @State private var busy = false
    var body: some View {
        List {
            if busy && destinations.isEmpty { ProgressView("Loading…").frame(maxWidth: .infinity) }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
                Button("Retry") { Task { await load() } }
            }
            ForEach(destinations) { destination in
                NavigationLink { S3DestinationEditor(destination: destination) } label: {
                    Label {
                        VStack(alignment: .leading) {
                            Text(destination.name)
                            Text(destination.bucket).font(.subheadline).foregroundStyle(.secondary)
                            Text(destination.region).font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "externaldrive.connected.to.line.below") }
                }
                .swipeActions(allowsFullSwipe: false) {
                    if manager.permissions.has("s3-destinations:delete", in: nil) {
                        Button("Delete", systemImage: "trash", role: .destructive) { deleteTarget = destination }
                    }
                }
            }
            if destinations.isEmpty && !busy && errorMessage == nil {
                ContentUnavailableView("No S3 Destinations", systemImage: "externaldrive.connected.to.line.below")
            }
            PaginatedListFooter(
                hasMore: hasMore, loadMoreError: loadMoreError,
                onRetry: { Task { await load(more: true) } },
                onLoadMore: { Task { await load(more: true) } }
            ).id(destinations.count)
        }
        .listStyle(.insetGrouped)
        .navigationTitle("S3 Destinations")
        .toolbar {
            if manager.permissions.has("s3-destinations:create", in: nil) {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add S3 Destination", systemImage: "plus") { creating = true }.labelStyle(.iconOnly)
                }
            }
        }
        .sheet(isPresented: $creating, onDismiss: { Task { await load() } }) {
            NavigationStack {
                S3DestinationEditor()
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { creating = false } } }
            }
        }
        .modifier(BackupSessionScope())
        .task(id: manager.clientGeneration) { await load() }
        .refreshable { await load() }
        .confirmationDialog("Delete S3 destination?", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let destination = deleteTarget { Task { await delete(destination) } } }
        } message: { Text("Destinations referenced by backups or policies cannot be deleted.") }
    }
    private func load(more: Bool = false) async {
        let scope = BackupRequestScope(manager)
        guard let client = manager.client else { return }
        let key = listIdentity
        guard loadingIdentity != key else { return }
        let request = UUID()
        requestID = request
        loadingIdentity = key
        if loadedIdentity != key { destinations = []; hasMore = false; loadedIdentity = key }
        busy = true; errorMessage = nil; loadMoreError = nil

        defer { if requestID == request { busy = false; loadingIdentity = nil } }
        do {
            let page = try await client.s3Destinations.list(query: .init(start: more ? destinations.count : 0, limit: 50))
            try scope.check(manager)
            guard key == listIdentity, requestID == request else { return }
            if !more { destinations = [] }
            destinations += page.data
            hasMore = destinations.count < page.pagination.totalItems
        } catch is CancellationError {} catch {
            guard key == listIdentity, requestID == request else { return }
            if more { loadMoreError = friendlyErrorMessage(error) }
            else { errorMessage = friendlyErrorMessage(error) }
        }
    }
    private func delete(_ destination: S3Destination) async {
        let scope = BackupRequestScope(manager)
        guard let client = manager.client else { return }
        do {
            let usage = try await client.s3Destinations.usage(id: destination.id)
            try scope.check(manager)
            guard !usage.inUse else {
                showToast(.error("This destination is still in use")); return
            }
            _ = try await client.s3Destinations.delete(id: destination.id)
            try scope.check(manager)
            await load()
        } catch is CancellationError {} catch { showToast(.error(friendlyErrorMessage(error))) }
    }
}

struct S3DestinationEditor: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.dismiss) private var dismiss
    var destination: S3Destination? = nil
    @State private var name = ""
    @State private var endpoint = ""
    @State private var bucket = ""
    @State private var region = "us-east-1"
    @State private var accessKeyID = ""
    @State private var secret = ""
    @State private var prefix = ""
    @State private var useSSL = true
    @State private var forcePathStyle = true
    @State private var busy = false
    @State private var errorMessage: String?
    private var canSave: Bool { manager.permissions.has(destination == nil ? "s3-destinations:create" : "s3-destinations:update", in: nil) }
    private var valid: Bool { !name.isEmpty && !bucket.isEmpty && !region.isEmpty && !accessKeyID.isEmpty && (destination != nil || !secret.isEmpty) }
    private var request: CreateS3Destination {
        .init(name: name, endpoint: endpoint, bucket: bucket, region: region, accessKeyId: accessKeyID, secretAccessKey: secret, prefix: prefix, useSsl: useSSL, forcePathStyle: forcePathStyle)
    }
    var body: some View {
        Form {
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            Section("Destination") {
                FormTextField(title: "Name", placeholder: "", text: $name, autocapitalization: .never, autocorrectionDisabled: true)
                FormTextField(title: "Endpoint", placeholder: "", text: $endpoint, keyboardType: .URL, autocapitalization: .never, autocorrectionDisabled: true)
                FormTextField(title: "Bucket", placeholder: "", text: $bucket, autocapitalization: .never, autocorrectionDisabled: true)
                FormTextField(title: "Region", placeholder: "", text: $region, autocapitalization: .never, autocorrectionDisabled: true)
                FormTextField(title: "Prefix", placeholder: "", text: $prefix, autocapitalization: .never, autocorrectionDisabled: true, layout: .stacked)
                Toggle("Use SSL", isOn: $useSSL)
                Toggle("Force path style", isOn: $forcePathStyle)
            }
            Section {
                FormTextField(title: "Access key ID", placeholder: "", text: $accessKeyID, autocapitalization: .never, autocorrectionDisabled: true).privacySensitive()
                FormSecureField(title: "Secret access key", placeholder: "", text: $secret).privacySensitive()
            } footer: { if destination != nil { Text("Leave the secret empty to keep the stored credential.") } }
            if manager.permissions.has("s3-destinations:test", in: nil) { Button("Test connection") { Task { await test() } }.disabled(!valid) }
        }
        .textInputAutocapitalization(.never).autocorrectionDisabled()
        .navigationTitle(destination?.name ?? "S3 Destination")
        .modifier(BackupSessionScope())
        .disabled(busy)
        .toolbar {
            if canSave {
                ToolbarItem(placement: .confirmationAction) {
                    Button(destination == nil ? "Create" : "Save") { Task { await save() } }.disabled(!valid || busy)
                }
            }
        }
        .onAppear {
            if let d = destination {
                name = d.name; endpoint = d.endpoint ?? ""; bucket = d.bucket; region = d.region
                accessKeyID = d.accessKeyId; prefix = d.prefix ?? ""; useSSL = d.useSsl; forcePathStyle = d.forcePathStyle
            }
        }
        .onDisappear { secret = "" }
    }
    private func test() async {
        let scope = BackupRequestScope(manager)
        guard let client = manager.client else { return }
        busy = true; defer { busy = false }
        do {
            if let destination { _ = try await client.s3Destinations.test(id: destination.id, configuration: request) }
            else { _ = try await client.s3Destinations.test(configuration: request) }
            try scope.check(manager); showToast(.success("S3 connection test succeeded"))
        } catch is CancellationError {} catch { errorMessage = friendlyErrorMessage(error) }
    }
    private func save() async {
        let scope = BackupRequestScope(manager)
        guard let client = manager.client, canSave else { return }
        busy = true; defer { busy = false }
        do {
            if let destination { _ = try await client.s3Destinations.update(id: destination.id, request: request) }
            else { _ = try await client.s3Destinations.create(request) }
            secret = ""; try scope.check(manager); showToast(.success("S3 destination saved")); dismiss()
        } catch is CancellationError {} catch { errorMessage = friendlyErrorMessage(error) }
    }
}
