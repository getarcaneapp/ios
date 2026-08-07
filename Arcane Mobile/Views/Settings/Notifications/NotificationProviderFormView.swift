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
    @State private var isAdvancedExpanded = false
    @State private var showsSaveBeforeTestConfirmation = false

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
    private var isValid: Bool { !state.enabled || state.isValid(for: provider) }

    var body: some View {
        Form {
            Section("Status") {
                Toggle("Enabled", isOn: $state.enabled)
            }

            if state.enabled {
                configurationSections
                eventSection
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }

            Section("Actions") {
                if state.enabled {
                    Picker("Test Type", selection: $selectedTestType) {
                        ForEach(NotificationTestType.allCases, id: \.rawValue) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                }

                if state.enabled {
                    Button("Send Test Notification", systemImage: "paperplane") {
                        if hasChanges {
                            showsSaveBeforeTestConfirmation = true
                        } else {
                            Task { await testNotification() }
                        }
                    }
                    .disabled(isSaving || isTesting || !isValid)
                }

                if isTesting {
                    ProgressView("Sending test…")
                }
            }
        }
        .navigationTitle(provider.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            saveButton
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 18)
        }
        .confirmationDialog(
            "Save Changes Before Testing?",
            isPresented: $showsSaveBeforeTestConfirmation,
            titleVisibility: .visible
        ) {
            Button("Save and Send Test") {
                Task { await testNotification() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The provider must be saved before Arcane can test the updated configuration.")
        }
    }

    private var saveButton: some View {
        Button {
            Task { _ = await save(dismissAfterSave: true) }
        } label: {
            ZStack {
                if isSaving {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: "checkmark")
                        .font(.title.weight(.semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .buttonStyle(.plain)
        .frame(width: 52, height: 52)
        .contentShape(.circle)
        .glassChipCompat(tint: Color.accentColor, interactive: true, in: .circle)
        .accessibilityLabel(existing == nil ? "Save" : "Update")
        .disabled(isSaving || isTesting || !isValid || !hasChanges)
        .opacity(!isSaving && (isTesting || !isValid || !hasChanges) ? 0.6 : 1)
    }

    @ViewBuilder
    private var configurationSections: some View {
        switch provider {
        case .discord:
            Section("Discord") {
                textField("Webhook ID", prompt: "Required", text: $state.webhookID)
                secureField("Webhook Token", text: $state.token)
                advancedSection {
                    textField("Username", text: $state.username)
                    urlField("Avatar URL", text: $state.avatarURL)
                }
            }
        case .email:
            Section("SMTP Server") {
                textField("Host", prompt: "Required", text: $state.host)
                numberField("Port", text: $state.port)
                emailField("From Address", text: $state.fromAddress)
                advancedSection {
                    textField("Username", text: $state.smtpUsername)
                    secureField("Password", text: $state.password)
                    Picker("TLS", selection: $state.tlsMode) {
                        Text("None").tag(EmailTLSMode.none.rawValue)
                        Text("StartTLS").tag(EmailTLSMode.starttls.rawValue)
                        Text("SSL/TLS").tag(EmailTLSMode.ssl.rawValue)
                    }
                    Picker("Authentication", selection: $state.authMode) {
                        Text("Auto").tag(EmailAuthMode.auto.rawValue)
                        Text("None").tag(EmailAuthMode.none.rawValue)
                        Text("PLAIN").tag(EmailAuthMode.plain.rawValue)
                        Text("LOGIN").tag(EmailAuthMode.login.rawValue)
                        Text("CRAM-MD5").tag(EmailAuthMode.crammd5.rawValue)
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
                advancedSection {
                    textField("Title", text: $state.title)
                    textField("Parse Mode", text: $state.parseMode)
                    Toggle("Link Previews", isOn: $state.preview)
                    Toggle("Notification Sound", isOn: $state.notification)
                }
            }
            valueRows(
                "Chat IDs",
                rows: $state.recipients,
                placeholder: "-1001234567890",
                addTitle: "Add Chat ID"
            )
        case .signal:
            Section("Signal Server") {
                textField("Host", prompt: "Required", text: $state.host)
                numberField("Port", text: $state.port)
                textField("Source", prompt: "+15551234567", text: $state.source)
                advancedSection {
                    textField("User", text: $state.user)
                    secureField("Password", text: $state.password)
                    secureField("Token", text: $state.token)
                    Toggle("Use HTTP", isOn: $state.disableTLS)
                }
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
                textField("Channel", text: $state.channel)
                advancedSection {
                    textField("Bot Name", text: $state.botName)
                    textField("Icon", text: $state.icon)
                    textField("Color", text: $state.color)
                    textField("Title", text: $state.title)
                    textField("Thread Timestamp", text: $state.threadTS)
                }
            }
        case .ntfy:
            Section("Ntfy Server") {
                textField("Host", prompt: "ntfy.sh", text: $state.host)
                textField("Topic", prompt: "Required", text: $state.topic)
                Picker("Priority", selection: $state.priority) {
                    Text("Min (1)").tag("min")
                    Text("Low (2)").tag("low")
                    Text("Default (3)").tag("default")
                    Text("High (4)").tag("high")
                    Text("Max/Urgent (5)").tag("max")
                }
                advancedSection {
                    numberField("Port", text: $state.port)
                    textField("Username", text: $state.username)
                    secureField("Password", text: $state.password)
                    textField("Title", text: $state.title)
                    urlField("Icon URL", text: $state.icon)
                    Toggle("Cache Messages", isOn: $state.cache)
                    Toggle("Forward to Firebase", isOn: $state.firebase)
                    Toggle("Use HTTP", isOn: $state.disableTLS)
                    Toggle("Skip TLS Verification", isOn: $state.disableTLSVerification)
                }
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
                textField("User Key", prompt: "Required", text: $state.user)
                advancedSection {
                    Picker("Priority", selection: $state.priority) {
                        ForEach(-2...2, id: \.self) { priority in
                            Text(verbatim: String(priority)).tag(String(priority))
                        }
                    }
                    textField("Title", text: $state.title)
                }
            }
            valueRows(
                "Devices",
                rows: $state.devices,
                placeholder: "iphone",
                addTitle: "Add Device"
            )
        case .gotify:
            Section("Gotify") {
                textField("Host", prompt: "Required", text: $state.host)
                secureField("App Token", text: $state.token)
                Picker("Priority", selection: $state.priority) {
                    ForEach(-2...10, id: \.self) { priority in
                        Text(verbatim: String(priority)).tag(String(priority))
                    }
                }
                advancedSection {
                    numberField("Port", text: $state.port)
                    textField("Path", text: $state.path)
                    textField("Title", text: $state.title)
                    Toggle("Use HTTP", isOn: $state.disableTLS)
                    Toggle("Skip TLS Verification", isOn: $state.insecureSkipVerify)
                    Toggle("Send Token in Header", isOn: $state.useHeader)
                }
            }
        case .matrix:
            Section("Matrix") {
                textField("Host", prompt: "Required", text: $state.host)
                textField("Rooms", prompt: "Required", text: $state.rooms)
                advancedSection {
                    numberField("Port", text: $state.port)
                    textField("Username", text: $state.username)
                    secureField("Password", text: $state.password)
                    Toggle("Skip TLS Verification", isOn: $state.disableTLSVerification)
                }
            }
        case .googlechat:
            Section("Google Chat") {
                urlField("Webhook URL", text: $state.webhookURL)
            }
        case .generic:
            Section("Request") {
                urlField("Webhook URL", text: $state.webhookURL)
                Picker("Method", selection: $state.method) {
                    Text("POST").tag("POST")
                    Text("PUT").tag("PUT")
                    Text("PATCH").tag("PATCH")
                }
                advancedSection {
                    textField("Content Type", text: $state.contentType)
                    Toggle("Use HTTP", isOn: $state.disableTLS)
                    if manager.supportsPost26MobileFeatures {
                        textField("Title Key", text: $state.titleKey)
                        textField("Message Key", text: $state.messageKey)
                        TextField(
                            "Payload Template",
                            text: $state.payloadTemplate,
                            prompt: Text("JSON payload template"),
                            axis: .vertical
                        )
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(4...10)
                        textField("Expected Response Contains", text: $state.successBodyContains)
                    }
                }
            }

            if isAdvancedExpanded {
                headerRows
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
                VStack(alignment: .leading) {
                    TextField("Header Name", text: $header.name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Header Value", text: $header.value)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .onDelete { offsets in
                state.headers.remove(atOffsets: offsets)
            }

            Button("Add Header", systemImage: "plus") {
                state.headers.append(NotificationHeaderRow())
            }
        } header: {
            Text("Headers")
        } footer: {
            if !state.headers.isEmpty {
                Text("Swipe left on a header to remove it.")
            }
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
                TextField(placeholder, text: $row.value)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .onDelete { offsets in
                rows.wrappedValue.remove(atOffsets: offsets)
            }

            Button(addTitle, systemImage: "plus") {
                rows.wrappedValue.append(NotificationValueRow())
            }
        } header: {
            Text(title)
        } footer: {
            if !rows.wrappedValue.isEmpty {
                Text("Swipe left on a row to remove it.")
            }
        }
    }

    private func advancedSection<Content: View>(
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        DisclosureGroup("Advanced", isExpanded: $isAdvancedExpanded) {
            content()
        }
    }

    private func textField(
        _ title: String,
        prompt: String = "Optional",
        text: Binding<String>
    ) -> some View {
        LabeledContent(title) {
            TextField(prompt, text: text)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }

    private func secureField(_ title: String, text: Binding<String>) -> some View {
        LabeledContent(title) {
            SecureField(
                existing == nil ? "Required" : "Keep current value",
                text: text
            )
            .multilineTextAlignment(.trailing)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }
    }

    private func numberField(_ title: String, text: Binding<String>) -> some View {
        LabeledContent(title) {
            TextField("Optional", text: text)
                .multilineTextAlignment(.trailing)
                .keyboardType(.numberPad)
        }
    }

    private func urlField(_ title: String, text: Binding<String>) -> some View {
        LabeledContent(title) {
            TextField("https://…", text: text)
                .multilineTextAlignment(.trailing)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }

    private func emailField(_ title: String, text: Binding<String>) -> some View {
        LabeledContent(title) {
            TextField("name@example.com", text: text)
                .multilineTextAlignment(.trailing)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
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
