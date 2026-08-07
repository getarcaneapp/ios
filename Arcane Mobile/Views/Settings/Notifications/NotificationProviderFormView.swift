import Arcane
import SwiftUI

struct NotificationProviderFormView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.dismiss) private var dismiss

    let provider: NotificationProvider
    let existing: NotificationSettings?
    let onSaved: () async -> Void

    @State private var state: NotificationProviderFormState
    @State private var originalState: NotificationProviderFormState
    @State private var isSaving = false
    @State private var isTesting = false
    @State private var errorMessage: String?
    @State private var selectedTestType = NotificationTestType.simple

    init(
        provider: NotificationProvider,
        existing: NotificationSettings?,
        onSaved: @escaping () async -> Void
    ) {
        self.provider = provider
        self.existing = existing
        self.onSaved = onSaved
        let initial = NotificationProviderFormState(provider: provider, existing: existing)
        _state = State(initialValue: initial)
        _originalState = State(initialValue: initial)
    }

    private var hasChanges: Bool { state != originalState }
    private var isValid: Bool { state.isValid(for: provider) }

    var body: some View {
        Form {
            Section("Status") {
                Toggle("Enabled", isOn: $state.enabled)
            }

            configurationSections
            eventSection

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }

            Section {
                Picker("Test Type", selection: $selectedTestType) {
                    ForEach(NotificationTestType.allCases, id: \.rawValue) { type in
                        Text(type.displayName).tag(type)
                    }
                }

                Button {
                    Task { _ = await save(dismissAfterSave: true) }
                } label: {
                    centeredAction(
                        title: existing == nil ? "Save" : "Update",
                        systemImage: nil,
                        isLoading: isSaving
                    )
                }
                .disabled(isSaving || isTesting || !isValid || !hasChanges)

                Button {
                    Task { await testNotification() }
                } label: {
                    centeredAction(
                        title: "Send Test Notification",
                        systemImage: "paperplane",
                        isLoading: isTesting
                    )
                }
                .disabled(isSaving || isTesting || !state.enabled || !isValid)
            }
        }
        .navigationTitle(provider.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var configurationSections: some View {
        switch provider {
        case .discord:
            Section("Discord") {
                textField("Webhook ID", text: $state.webhookID)
                secureField("Webhook Token", text: $state.token)
                textField("Username", text: $state.username)
                urlField("Avatar URL", text: $state.avatarURL)
            }
        case .email:
            Section("SMTP Server") {
                textField("Host", text: $state.host)
                numberField("Port", text: $state.port)
                textField("Username", text: $state.smtpUsername)
                secureField("Password", text: $state.password)
                emailField("From Address", text: $state.fromAddress)
                Picker("TLS", selection: $state.tlsMode) {
                    ForEach(EmailTLSMode.allCases, id: \.rawValue) { mode in
                        Text(mode.rawValue.uppercased()).tag(mode.rawValue)
                    }
                }
                Picker("Authentication", selection: $state.authMode) {
                    ForEach(EmailAuthMode.allCases, id: \.rawValue) { mode in
                        Text(mode.rawValue.uppercased()).tag(mode.rawValue)
                    }
                }
            }
            valueRows(
                "Recipients",
                rows: $state.recipients,
                placeholder: "alerts@example.com",
                addTitle: "Add Recipient"
            )
        case .telegram:
            Section("Telegram") {
                secureField("Bot Token", text: $state.token)
                Toggle("Link Preview", isOn: $state.preview)
                Toggle("Send Notification", isOn: $state.notification)
                textField("Parse Mode", text: $state.parseMode)
                textField("Title", text: $state.title)
            }
            valueRows(
                "Chat IDs",
                rows: $state.recipients,
                placeholder: "-1001234567890",
                addTitle: "Add Chat ID"
            )
        case .signal:
            Section("Signal Server") {
                textField("Host", text: $state.host)
                numberField("Port", text: $state.port)
                textField("User", text: $state.user)
                secureField("Password", text: $state.password)
                secureField("Token", text: $state.token)
                textField("Source", text: $state.source)
                Toggle("Disable TLS", isOn: $state.disableTLS)
            }
            valueRows(
                "Recipients",
                rows: $state.recipients,
                placeholder: "+15551234567",
                addTitle: "Add Recipient"
            )
        case .slack:
            Section("Slack") {
                secureField("Token", text: $state.token)
                textField("Bot Name", text: $state.botName)
                textField("Icon", text: $state.icon)
                textField("Color", text: $state.color)
                textField("Title", text: $state.title)
                textField("Channel", text: $state.channel)
                textField("Thread Timestamp", text: $state.threadTS)
            }
        case .ntfy:
            Section("Ntfy Server") {
                textField("Host", text: $state.host)
                numberField("Port", text: $state.port)
                textField("Topic", text: $state.topic)
                textField("Username", text: $state.username)
                secureField("Password", text: $state.password)
                textField("Title", text: $state.title)
                textField("Priority", text: $state.priority)
                urlField("Icon URL", text: $state.icon)
                Toggle("Cache", isOn: $state.cache)
                Toggle("Firebase", isOn: $state.firebase)
                Toggle("Disable TLS", isOn: $state.disableTLS)
                Toggle("Disable TLS Verification", isOn: $state.disableTLSVerification)
            }
            valueRows(
                "Tags",
                rows: $state.tags,
                placeholder: "warning",
                addTitle: "Add Tag"
            )
        case .pushover:
            Section("Pushover") {
                secureField("API Token", text: $state.token)
                textField("User Key", text: $state.user)
                numberField("Priority", text: $state.priority)
                textField("Title", text: $state.title)
            }
            valueRows(
                "Devices",
                rows: $state.devices,
                placeholder: "iphone",
                addTitle: "Add Device"
            )
        case .gotify:
            Section("Gotify") {
                textField("Host", text: $state.host)
                numberField("Port", text: $state.port)
                secureField("App Token", text: $state.token)
                textField("Path", text: $state.path)
                numberField("Priority", text: $state.priority)
                textField("Title", text: $state.title)
                Toggle("Disable TLS", isOn: $state.disableTLS)
                Toggle("Skip TLS Verification", isOn: $state.insecureSkipVerify)
                Toggle("Send Token in Header", isOn: $state.useHeader)
            }
        case .matrix:
            Section("Matrix") {
                textField("Host", text: $state.host)
                numberField("Port", text: $state.port)
                textField("Rooms", text: $state.rooms)
                textField("Username", text: $state.username)
                secureField("Password", text: $state.password)
                Toggle("Disable TLS Verification", isOn: $state.disableTLSVerification)
            }
        case .googlechat:
            Section("Google Chat") {
                secureField("Webhook URL", text: $state.webhookURL)
            }
        case .generic:
            Section("Request") {
                urlField("Webhook URL", text: $state.webhookURL)
                Picker("Method", selection: $state.method) {
                    Text("POST").tag("POST")
                    Text("PUT").tag("PUT")
                    Text("PATCH").tag("PATCH")
                }
                textField("Content Type", text: $state.contentType)
                Toggle("Disable TLS", isOn: $state.disableTLS)
            }

            headerRows

            if manager.supportsPost26MobileFeatures {
                Section("Payload") {
                    textField("Title Key", text: $state.titleKey)
                    textField("Message Key", text: $state.messageKey)
                    FormTextField(
                        title: "Payload Template",
                        placeholder: "JSON payload template",
                        text: $state.payloadTemplate,
                        autocapitalization: .never,
                        autocorrectionDisabled: true,
                        axis: .vertical,
                        lineLimit: 4...10
                    )
                    textField("Expected Response Contains", text: $state.successBodyContains)
                }
            }
        }
    }

    private var eventSection: some View {
        Section {
            Toggle("Image Updates", isOn: $state.events.imageUpdate)
            Toggle("Container Updates", isOn: $state.events.containerUpdate)
            Toggle("Vulnerabilities", isOn: $state.events.vulnerabilityFound)
            Toggle("Prune Reports", isOn: $state.events.pruneReport)
            Toggle("Auto-Heal", isOn: $state.events.autoHeal)
        } header: {
            Text("Event Subscriptions")
        } footer: {
            Text("Choose which events trigger notifications for this provider.")
        }
    }

    private var headerRows: some View {
        Section {
            ForEach($state.headers) { $header in
                VStack(spacing: 8) {
                    HStack {
                        TextField("Header name", text: $header.name)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button(role: .destructive) {
                            state.headers.removeAll { $0.id == header.id }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove header")
                    }
                    TextField("Header value", text: $header.value)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            Button {
                state.headers.append(NotificationHeaderRow())
            } label: {
                Label("Add Header", systemImage: "plus")
            }
        } header: {
            Text("Headers")
        }
    }

    private func valueRows(
        _ title: String,
        rows: Binding<[NotificationValueRow]>,
        placeholder: String,
        addTitle: String
    ) -> some View {
        Section {
            ForEach(rows) { $row in
                HStack {
                    TextField(placeholder, text: $row.value)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button(role: .destructive) {
                        rows.wrappedValue.removeAll { $0.id == row.id }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(title.lowercased()) row")
                }
            }
            Button {
                rows.wrappedValue.append(NotificationValueRow())
            } label: {
                Label(addTitle, systemImage: "plus")
            }
        } header: {
            Text(title)
        }
    }

    private func textField(_ title: String, text: Binding<String>) -> some View {
        FormTextField(
            title: title,
            placeholder: "Optional",
            text: text,
            autocapitalization: .never,
            autocorrectionDisabled: true
        )
    }

    private func secureField(_ title: String, text: Binding<String>) -> some View {
        FormSecureField(
            title: title,
            placeholder: existing == nil ? "Required" : "Leave unchanged to keep current value",
            text: text
        )
    }

    private func numberField(_ title: String, text: Binding<String>) -> some View {
        FormTextField(
            title: title,
            placeholder: "Optional",
            text: text,
            keyboardType: .numberPad
        )
    }

    private func urlField(_ title: String, text: Binding<String>) -> some View {
        FormTextField(
            title: title,
            placeholder: "https://…",
            text: text,
            keyboardType: .URL,
            textContentType: .URL,
            autocapitalization: .never,
            autocorrectionDisabled: true
        )
    }

    private func emailField(_ title: String, text: Binding<String>) -> some View {
        FormTextField(
            title: title,
            placeholder: "name@example.com",
            text: text,
            keyboardType: .emailAddress,
            textContentType: .emailAddress,
            autocapitalization: .never,
            autocorrectionDisabled: true
        )
    }

    private func centeredAction(
        title: String,
        systemImage: String?,
        isLoading: Bool
    ) -> some View {
        HStack {
            Spacer()
            if isLoading {
                ProgressView().scaleEffect(0.8)
            } else if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
            Spacer()
        }
    }

    @discardableResult
    private func save(dismissAfterSave: Bool) async -> Bool {
        guard let client = manager.client, isValid else { return false }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            _ = try await client.notifications.upsertSettings(
                UpdateNotificationSettings(
                    enabled: state.enabled,
                    config: state.configuration(
                        for: provider,
                        supportsPost26Features: manager.supportsPost26MobileFeatures
                    )
                ),
                envID: manager.activeEnvironmentID
            )
            originalState = state
            await onSaved()
            if dismissAfterSave { dismiss() }
            return true
        } catch {
            errorMessage = friendlyErrorMessage(error)
            return false
        }
    }

    private func testNotification() async {
        guard let client = manager.client else { return }
        if hasChanges {
            let saved = await save(dismissAfterSave: false)
            guard saved else { return }
        }

        isTesting = true
        defer { isTesting = false }
        do {
            let response = try await client.notifications.test(
                provider: provider,
                type: selectedTestType,
                envID: manager.activeEnvironmentID
            )
            if let warning = response.warning, !warning.isEmpty {
                showToast(.info(warning))
            } else {
                showToast(.success("Test notification sent"))
            }
        } catch {
            showToast(.error(friendlyErrorMessage(error)))
        }
    }
}

private extension NotificationTestType {
    var displayName: String {
        switch self {
        case .simple: "Simple"
        case .imageUpdate: "Image Update"
        case .batchImageUpdate: "Batch Image Update"
        case .vulnerabilityFound: "Vulnerability Found"
        case .pruneReport: "Prune Report"
        case .autoHeal: "Auto-Heal"
        }
    }
}
