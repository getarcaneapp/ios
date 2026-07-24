import SwiftUI
import Arcane

private struct JobScheduleField: Hashable {
    let key: String
    let label: String
    let icon: String
    let tint: Color
}

private let jobScheduleFields: [JobScheduleField] = [
    .init(key: "autoHealInterval", label: "Auto Heal", icon: "heart.text.square.fill", tint: .pink),
    .init(key: "autoUpdateInterval", label: "Auto Update", icon: "arrow.triangle.2.circlepath", tint: .blue),
    .init(key: "dockerClientRefreshInterval", label: "Docker Client Refresh", icon: "shippingbox.fill", tint: .blue),
    .init(key: "environmentHealthInterval", label: "Environment Health", icon: "waveform.path.ecg", tint: .green),
    .init(key: "eventCleanupInterval", label: "Event Cleanup", icon: "trash.fill", tint: .red),
    .init(key: "gitopsSyncInterval", label: "GitOps Sync", icon: "arrow.triangle.merge", tint: .indigo),
    .init(key: "pollingInterval", label: "Polling", icon: "dot.radiowaves.left.and.right", tint: .teal),
    .init(key: "scheduledPruneInterval", label: "Scheduled Prune", icon: "scissors", tint: .orange),
    .init(key: "vulnerabilityScanInterval", label: "Vulnerability Scan", icon: "shield.lefthalf.filled", tint: .purple),
]

struct JobScheduleConfigView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    let environmentID: EnvironmentID

    @State private var values: [String: String] = [:]
    @State private var original: [String: String] = [:]
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var hasChanges: Bool {
        jobScheduleFields.contains { values[$0.key] != original[$0.key] }
    }

    var body: some View {
        Form {
            if isLoading && values.isEmpty {
                Section {
                    HStack {
                        Spacer()
                        ProgressView("Loading schedules…")
                        Spacer()
                    }
                }
            } else {
                Section {
                    ForEach(jobScheduleFields, id: \.key) { field in
                        scheduleRow(field)
                    }
                } footer: {
                    Text("Cron expressions accept 5- or 6-field syntax. Changes save to the active environment's settings.")
                }

                if hasChanges {
                    Section {
                        Button(role: .destructive) {
                            for field in jobScheduleFields {
                                values[field.key] = original[field.key] ?? ""
                            }
                        } label: {
                            HStack {
                                Spacer()
                                Text("Discard Changes")
                                Spacer()
                            }
                        }
                    }
                }

                if let error = errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }
                }

            }
        }
        .navigationTitle("Schedules")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { Task { await load(refresh: true) } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh")
                .disabled(isLoading)
            }
            if #available(iOS 26, *) {
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        ProgressView()
                    } else {
                        Text("Save")
                    }
                }
                .disabled(!hasChanges || isSaving)
            }
        }
        .task { await load() }
        .refreshable { await load(refresh: true) }
    }

    @ViewBuilder
    private func scheduleRow(_ field: JobScheduleField) -> some View {
        let binding = Binding<String>(
            get: { values[field.key] ?? "" },
            set: { values[field.key] = $0 }
        )
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: field.icon)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(field.tint)
                    .frame(width: 28, height: 28)
                    .background(field.tint.opacity(0.15), in: .circle)
                Text(field.label)
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            FormTextField(
                title: "Cron Expression",
                placeholder: "* * * * *",
                text: binding,
                autocapitalization: .never,
                autocorrectionDisabled: true,
                monospaced: true,
                helper: CronExpression.readable(binding.wrappedValue)
            )
        }
        .padding(.vertical, 4)
    }

    private func load(refresh: Bool = false) async {
        guard let client = manager.client else { return }
        if values.isEmpty { isLoading = true }
        if refresh { errorMessage = nil }
        defer { isLoading = false }
        do {
            let path = client.rest.environmentPath(environmentID, "settings")
            let raw = try await client.transport.rawRequest(path, body: Optional<String>.none)
            let dtos = try JSONDecoder().decode([PublicSetting].self, from: raw)
            var dict: [String: String] = [:]
            for dto in dtos where jobScheduleFields.contains(where: { $0.key == dto.key }) {
                dict[dto.key] = dto.value
            }
            values = dict
            original = dict
            errorMessage = nil
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func save() async {
        guard let client = manager.client else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        var changed: [String: String] = [:]
        for field in jobScheduleFields {
            let value = values[field.key] ?? ""
            if value != original[field.key] {
                changed[field.key] = value
            }
        }
        guard !changed.isEmpty else { return }

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: changed)
            let update = try JSONDecoder().decode(UpdateSettings.self, from: jsonData)
            let path = client.rest.environmentPath(environmentID, "settings")
            let _: [PublicSetting] = try await client.rest.put(path, body: update)
            for (key, value) in changed {
                original[key] = value
            }
            showToast(.success("Schedules saved"))
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }
}
