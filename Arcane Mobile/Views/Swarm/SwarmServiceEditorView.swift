import Arcane
import SwiftUI

/// Create or edit a swarm service. Edits patch the service's existing spec so
/// settings this form doesn't cover are preserved.
struct SwarmServiceEditorView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutationStore
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let environmentID: EnvironmentID
    let existing: SwarmServiceInspect?

    @State private var draft: SwarmServiceSpecDraft
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let initialDraft: SwarmServiceSpecDraft

    init(environmentID: EnvironmentID, existing: SwarmServiceInspect?) {
        self.environmentID = environmentID
        self.existing = existing
        let draft = existing.map { SwarmServiceSpecDraft(spec: $0.spec) } ?? SwarmServiceSpecDraft()
        initialDraft = draft
        _draft = State(initialValue: draft)
    }

    private var isEditing: Bool { existing != nil }
    private var hasChanges: Bool { draft != initialDraft }

    var body: some View {
        NavigationStack {
            Form {
                Section("Service") {
                    FormTextField(
                        title: "Name",
                        placeholder: "web",
                        text: $draft.name,
                        autocapitalization: .never,
                        autocorrectionDisabled: true,
                        helper: isEditing ? "Docker can't rename a service." : nil,
                        disabled: isEditing
                    )
                    FormTextField(
                        title: "Image",
                        placeholder: "nginx:latest",
                        text: $draft.image,
                        autocapitalization: .never,
                        autocorrectionDisabled: true
                    )
                }
                modeSection
                portsSection
                pairsSection(title: "Environment", pairs: $draft.env, keyPlaceholder: "KEY", addTitle: "Add Variable")
                mountsSection
                pairsSection(
                    title: "Labels", pairs: $draft.labels, keyPlaceholder: "com.example.key", addTitle: "Add Label")
                Section {
                    FormTextField(
                        title: "Command", placeholder: "Image default", text: $draft.command,
                        autocapitalization: .never, autocorrectionDisabled: true, monospaced: true)
                    FormTextField(
                        title: "Args", placeholder: "None", text: $draft.args,
                        autocapitalization: .never, autocorrectionDisabled: true, monospaced: true)
                    FormTextField(
                        title: "Working Dir", placeholder: "Image default", text: $draft.workingDir,
                        autocapitalization: .never, autocorrectionDisabled: true)
                    FormTextField(
                        title: "User", placeholder: "Image default", text: $draft.user,
                        autocapitalization: .never, autocorrectionDisabled: true)
                    FormTextField(
                        title: "Hostname", placeholder: "Automatic", text: $draft.hostname,
                        autocapitalization: .never, autocorrectionDisabled: true)
                } header: {
                    Text("Advanced")
                } footer: {
                    Text("Separate arguments with spaces; quote values that contain spaces.")
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Service" : "Create Service")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                AppToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Create") {
                        Task { await save() }
                    }
                    .disabled(isSaving || !draft.isValid || (isEditing && !hasChanges))
                }
            }
            .interactiveDismissDisabled(isSaving || hasChanges)
        }
    }

    @ViewBuilder
    private var modeSection: some View {
        Section("Scheduling") {
            if draft.mode == .job {
                LabeledContent("Mode", value: "Job")
            } else {
                Picker("Mode", selection: $draft.mode) {
                    Text("Replicated").tag(SwarmServiceSpecDraft.Mode.replicated)
                    Text("Global").tag(SwarmServiceSpecDraft.Mode.global)
                }
                .disabled(isEditing)
                if draft.mode == .replicated {
                    Stepper(value: $draft.replicas, in: 0...1_000) {
                        LabeledContent("Replicas") {
                            Text(verbatim: String(draft.replicas)).monospacedDigit()
                        }
                    }
                }
            }
        }
    }

    private var portsSection: some View {
        Section("Ports") {
            ForEach($draft.ports) { $port in
                HStack(spacing: 8) {
                    TextField("Published", text: $port.published)
                        .keyboardType(.numberPad)
                        .font(.body.monospacedDigit())
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField("Target", text: $port.target)
                        .keyboardType(.numberPad)
                        .font(.body.monospacedDigit())
                    Picker("Protocol", selection: $port.proto) {
                        Text("TCP").tag("tcp")
                        Text("UDP").tag("udp")
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            .onDelete { draft.ports.remove(atOffsets: $0) }
            Button {
                draft.ports.append(.init())
            } label: {
                Label("Add Port", systemImage: "plus")
            }
        }
    }

    private var mountsSection: some View {
        Section("Mounts") {
            ForEach($draft.mounts) { $mount in
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Type", selection: $mount.type) {
                        Text("Volume").tag("volume")
                        Text("Bind").tag("bind")
                        Text("tmpfs").tag("tmpfs")
                    }
                    .pickerStyle(.segmented)
                    if mount.type != "tmpfs" {
                        TextField(mount.type == "bind" ? "Host path" : "Volume name", text: $mount.source)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    TextField("Container path", text: $mount.target)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("Read-only", isOn: $mount.readOnly)
                }
                .padding(.vertical, 4)
            }
            .onDelete { draft.mounts.remove(atOffsets: $0) }
            Button {
                draft.mounts.append(.init())
            } label: {
                Label("Add Mount", systemImage: "plus")
            }
        }
    }

    private func pairsSection(
        title: String,
        pairs: Binding<[SwarmServiceSpecDraft.Pair]>,
        keyPlaceholder: String,
        addTitle: String
    ) -> some View {
        Section(title) {
            ForEach(pairs) { $pair in
                HStack(spacing: 8) {
                    TextField(keyPlaceholder, text: $pair.key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                    Text(verbatim: "=")
                        .foregroundStyle(.secondary)
                    TextField("value", text: $pair.value)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                }
            }
            .onDelete { pairs.wrappedValue.remove(atOffsets: $0) }
            Button {
                pairs.wrappedValue.append(.init())
            } label: {
                Label(addTitle, systemImage: "plus")
            }
        }
    }

    private func save() async {
        guard let client = manager.client else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let spec = draft.apply(to: existing?.spec)
            let warnings: [String]?
            if let existing {
                let response = try await client.swarm.updateService(
                    existing.id,
                    SwarmServiceUpdateRequest(version: existing.version.swarmVersionIndex ?? 0, spec: spec),
                    envID: environmentID
                )
                warnings = response.warnings
            } else {
                let response = try await client.swarm.createService(
                    SwarmServiceCreateRequest(spec: spec), envID: environmentID)
                warnings = response.warnings
            }
            await manager.swarmChanged(environmentID, mutationStore: mutationStore)
            showToast(.success(isEditing ? "Service updated" : "Service created"))
            if let warning = warnings?.first { showToast(.info(warning)) }
            dismiss()
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }
}
