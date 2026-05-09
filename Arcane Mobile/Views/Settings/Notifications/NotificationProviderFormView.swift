import SwiftUI
import Arcane
import OpenAPIRuntime

struct NotificationProviderFormView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.dismiss) private var dismiss

    let provider: NotificationProvider
    let existing: NotificationResponse?
    let onSaved: () async -> Void

    @State private var formValues: [String: String] = [:]
    @State private var enabled = false
    @State private var events = EventSubscriptions()
    @State private var isSaving = false
    @State private var isTesting = false
    @State private var errorMessage: String?
    @State private var testResult: String?

    // Snapshots taken in `populateForm` so Save can stay disabled until the
    // user actually edits something (or, for new providers, fills required fields).
    @State private var originalFormValues: [String: String] = [:]
    @State private var originalEnabled = false
    @State private var originalEvents = EventSubscriptions()

    private var fields: [ProviderFieldDescriptor] { fieldsForProvider(provider) }
    private var isEditing: Bool { existing != nil }

    private var hasChanges: Bool {
        guard isEditing else { return isValid }
        return formValues != originalFormValues
            || enabled != originalEnabled
            || events != originalEvents
    }

    var body: some View {
        Form {
            Section("Status") {
                Toggle("Enabled", isOn: $enabled)
            }

            Section("Configuration") {
                ForEach(fields) { field in
                    dynamicField(field)
                }
            }

            Section {
                ForEach(EventSubscriptions.keys, id: \.key) { item in
                    Toggle(item.label, isOn: eventBinding(for: item.key))
                }
            } header: {
                Text("Event Subscriptions")
            } footer: {
                Text("Choose which events trigger notifications for this provider.")
            }

            if let error = errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    Task { await save() }
                } label: {
                    HStack {
                        Spacer()
                        if isSaving {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Text(isEditing ? "Update" : "Save")
                        }
                        Spacer()
                    }
                }
                .disabled(isSaving || !isValid || !hasChanges)
            }

            Section {
                Button {
                    Task { await testNotification() }
                } label: {
                    HStack {
                        Spacer()
                        if isTesting {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Label("Send Test Notification", systemImage: "paperplane")
                        }
                        Spacer()
                    }
                }
                .disabled(isTesting || !enabled)

                if let result = testResult {
                    Label(result, systemImage: result.contains("Success") ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(result.contains("Success") ? .green : .red)
                        .font(.caption)
                }
            }
        }
        .navigationTitle(provider.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { populateForm() }
    }

    // MARK: - Dynamic Field Rendering

    @ViewBuilder
    private func dynamicField(_ field: ProviderFieldDescriptor) -> some View {
        let binding = stringBinding(for: field.key)

        switch field.kind {
        case .text:
            TextField(field.label, text: binding, prompt: Text(field.placeholder))
                .autocapitalization(.none)
        case .email:
            TextField(field.label, text: binding, prompt: Text(field.placeholder))
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .autocapitalization(.none)
        case .password:
            SecureField(field.label, text: binding, prompt: Text(field.placeholder))
        case .number:
            TextField(field.label, text: binding, prompt: Text(field.placeholder))
                .keyboardType(.numberPad)
        case .url:
            TextField(field.label, text: binding, prompt: Text(field.placeholder))
                .keyboardType(.URL)
                .textContentType(.URL)
                .autocapitalization(.none)
        case .toggle:
            Toggle(field.label, isOn: boolBinding(for: field.key))
        case .textarea:
            TextField(field.label, text: binding, prompt: Text(field.placeholder), axis: .vertical)
                .lineLimit(2...5)
                .autocapitalization(.none)
        case .picker(let options):
            Picker(field.label, selection: binding) {
                ForEach(options) { option in
                    Text(option.label).tag(option.value)
                }
            }
        }
    }

    // MARK: - Bindings

    private func stringBinding(for key: String) -> Binding<String> {
        Binding(
            get: { formValues[key] ?? "" },
            set: { formValues[key] = $0 }
        )
    }

    private func boolBinding(for key: String) -> Binding<Bool> {
        Binding(
            get: { formValues[key] == "true" },
            set: { formValues[key] = String($0) }
        )
    }

    private func eventBinding(for key: String) -> Binding<Bool> {
        Binding(
            get: {
                switch key {
                case "eventImageUpdate": return events.imageUpdate
                case "eventContainerUpdate": return events.containerUpdate
                case "eventVulnerabilityFound": return events.vulnerabilityFound
                case "eventPruneReport": return events.pruneReport
                case "eventAutoHeal": return events.autoHeal
                default: return false
                }
            },
            set: { newValue in
                switch key {
                case "eventImageUpdate": events.imageUpdate = newValue
                case "eventContainerUpdate": events.containerUpdate = newValue
                case "eventVulnerabilityFound": events.vulnerabilityFound = newValue
                case "eventPruneReport": events.pruneReport = newValue
                case "eventAutoHeal": events.autoHeal = newValue
                default: break
                }
            }
        )
    }

    // MARK: - Validation

    private var isValid: Bool {
        for field in fields where field.required {
            let value = formValues[field.key] ?? ""
            if value.isEmpty { return false }
        }
        return true
    }

    // MARK: - Form Population

    private func populateForm() {
        for field in fields {
            if formValues[field.key] == nil {
                formValues[field.key] = field.defaultValue
            }
        }

        if let existing {
            enabled = existing.enabled
            let extracted = extractConfigValues(existing.config)
            for (key, value) in extracted {
                if EventSubscriptions.keys.contains(where: { $0.key == key }) {
                    continue
                }
                formValues[key] = value
            }
            events = EventSubscriptions.from(extracted)
        }

        // Snapshot for dirty-state comparison.
        originalFormValues = formValues
        originalEnabled = enabled
        originalEvents = events
    }

    // MARK: - API

    private func save() async {
        guard let client = manager.client else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        let config = buildConfigPayload(formValues, provider: provider, events: events)
        let body = NotificationUpdate(
            config: config,
            enabled: enabled,
            provider: provider.rawValue
        )

        do {
            let path = client.rest.environmentPath(manager.activeEnvironmentID, "notifications/settings")
            let _ = try await client.transport.rawRequest(path, method: "POST", body: body)
            await onSaved()
            dismiss()
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func testNotification() async {
        guard let client = manager.client else { return }
        isTesting = true
        testResult = nil
        defer { isTesting = false }
        do {
            let path = client.rest.environmentPath(manager.activeEnvironmentID, "notifications/test/\(provider.rawValue)")
            let _: DataResponse<String> = try await client.rest.post(path, body: String?.none)
            testResult = "Success — test notification sent"
        } catch {
            testResult = friendlyErrorMessage(error)
        }
    }
}
