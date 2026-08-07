import Arcane
import SwiftUI

extension NotificationProvider: @retroactive Identifiable {
    public var id: String { rawValue }

    var displayName: String {
        switch self {
        case .discord: "Discord"
        case .email: "Email"
        case .telegram: "Telegram"
        case .signal: "Signal"
        case .slack: "Slack"
        case .ntfy: "Ntfy"
        case .pushover: "Pushover"
        case .gotify: "Gotify"
        case .matrix: "Matrix"
        case .googlechat: "Google Chat"
        case .generic: "Generic"
        }
    }

    var systemImage: String {
        switch self {
        case .discord: "bubble.left.fill"
        case .email: "envelope.fill"
        case .telegram: "paperplane.fill"
        case .signal: "lock.fill"
        case .slack: "number"
        case .ntfy: "bell.fill"
        case .pushover: "iphone.radiowaves.left.and.right"
        case .gotify: "arrow.up.message.fill"
        case .matrix: "square.grid.3x3.fill"
        case .googlechat: "message.fill"
        case .generic: "link"
        }
    }

    var iconColor: Color {
        switch self {
        case .discord: .indigo
        case .email: .blue
        case .telegram: .cyan
        case .signal: .blue
        case .slack: .purple
        case .ntfy: .green
        case .pushover: .teal
        case .gotify: .orange
        case .matrix: .green
        case .googlechat: .blue
        case .generic: .gray
        }
    }
}

typealias NotificationValueRow = StableStringRow
typealias NotificationHeaderRow = StableHeaderRow

struct EventSubscriptions: Equatable {
    var imageUpdate = true
    var containerUpdate = true
    var vulnerabilityFound = true
    var pruneReport = false
    var autoHeal = false

    init(events: NotificationEvents = .defaults) {
        imageUpdate = events.imageUpdate
        containerUpdate = events.containerUpdate
        vulnerabilityFound = events.vulnerabilityFound
        pruneReport = events.pruneReport
        autoHeal = events.autoHeal
    }

    var sdkValue: NotificationEvents {
        NotificationEvents(
            imageUpdate: imageUpdate,
            containerUpdate: containerUpdate,
            vulnerabilityFound: vulnerabilityFound,
            pruneReport: pruneReport,
            autoHeal: autoHeal
        )
    }
}

struct NotificationProviderFormState: Equatable {
    var enabled = false
    var events = EventSubscriptions()

    var webhookID = ""
    var webhookURL = ""
    var token = ""
    var username = ""
    var password = ""
    var title = ""
    var host = ""
    var port = ""
    var path = ""
    var priority = "0"
    var disableTLS = false
    var disableTLSVerification = false

    var avatarURL = ""

    var smtpUsername = ""
    var fromAddress = ""
    var tlsMode = EmailTLSMode.starttls.rawValue
    var authMode = EmailAuthMode.auto.rawValue
    var recipients: [NotificationValueRow] = []

    var preview = true
    var notification = true
    var parseMode = ""

    var user = ""
    var source = ""

    var botName = ""
    var icon = ""
    var color = ""
    var channel = ""
    var threadTS = ""

    var topic = ""
    var tags: [NotificationValueRow] = []
    var cache = true
    var firebase = true

    var devices: [NotificationValueRow] = []

    var insecureSkipVerify = false
    var useHeader = false

    var rooms = ""

    var method = "POST"
    var contentType = "application/json"
    var titleKey = "title"
    var messageKey = "message"
    var headers: [NotificationHeaderRow] = []
    var successBodyContains = ""
    var payloadTemplate = ""

    init(provider: NotificationProvider, existing: NotificationSettings?) {
        switch provider {
        case .email:
            port = "587"
        case .signal:
            port = "8080"
        case .ntfy:
            port = "443"
        case .pushover:
            priority = "0"
        case .gotify:
            priority = "5"
        default:
            break
        }
        guard let existing else { return }
        enabled = existing.enabled

        switch existing.config {
        case .discord(let config):
            webhookID = config.webhookId
            token = config.token ?? ""
            username = config.username ?? ""
            avatarURL = config.avatarUrl ?? ""
            events = EventSubscriptions(events: config.events ?? .defaults)
        case .email(let config):
            host = config.smtpHost
            port = String(config.smtpPort)
            smtpUsername = config.smtpUsername
            password = config.smtpPassword ?? ""
            fromAddress = config.fromAddress
            recipients = config.toAddresses.map { NotificationValueRow(value: $0) }
            tlsMode = config.tlsMode.rawValue
            authMode = (config.authMode ?? .auto).rawValue
            events = EventSubscriptions(events: config.events ?? .defaults)
        case .telegram(let config):
            token = config.botToken ?? ""
            recipients = config.chatIds.map { NotificationValueRow(value: $0) }
            preview = config.preview
            notification = config.notification
            parseMode = config.parseMode ?? ""
            title = config.title ?? ""
            events = EventSubscriptions(events: config.events ?? .defaults)
        case .signal(let config):
            host = config.host
            port = String(config.port)
            user = config.user ?? ""
            password = config.password ?? ""
            token = config.token ?? ""
            source = config.source
            recipients = config.recipients.map { NotificationValueRow(value: $0) }
            disableTLS = config.disableTls
            events = EventSubscriptions(events: config.events ?? .defaults)
        case .slack(let config):
            token = config.token ?? ""
            botName = config.botName ?? ""
            icon = config.icon ?? ""
            color = config.color ?? ""
            title = config.title ?? ""
            channel = config.channel ?? ""
            threadTS = config.threadTs ?? ""
            events = EventSubscriptions(events: config.events ?? .defaults)
        case .ntfy(let config):
            host = config.host
            port = String(config.port)
            topic = config.topic
            username = config.username ?? ""
            password = config.password ?? ""
            title = config.title ?? ""
            priority = config.priority ?? ""
            tags = (config.tags ?? []).map { NotificationValueRow(value: $0) }
            icon = config.icon ?? ""
            cache = config.cache
            firebase = config.firebase
            disableTLS = config.disableTls
            disableTLSVerification = config.disableTlsVerification
            events = EventSubscriptions(events: config.events ?? .defaults)
        case .pushover(let config):
            token = config.token ?? ""
            user = config.user
            devices = (config.devices ?? []).map { NotificationValueRow(value: $0) }
            priority = String(config.priority)
            title = config.title ?? ""
            events = EventSubscriptions(events: config.events ?? .defaults)
        case .gotify(let config):
            host = config.host
            port = config.port.map(String.init) ?? ""
            token = config.token ?? ""
            path = config.path ?? ""
            priority = config.priority.map(String.init) ?? ""
            title = config.title ?? ""
            disableTLS = config.disableTls
            insecureSkipVerify = config.insecureSkipVerify
            useHeader = config.useHeader
            events = EventSubscriptions(events: config.events ?? .defaults)
        case .matrix(let config):
            host = config.host
            port = config.port.map(String.init) ?? ""
            rooms = config.rooms
            username = config.username ?? ""
            password = config.password ?? ""
            disableTLSVerification = config.disableTlsVerification
            events = EventSubscriptions(events: config.events ?? .defaults)
        case .googlechat(let config):
            webhookURL = config.webhookUrl ?? ""
            events = EventSubscriptions(events: config.events ?? .defaults)
        case .generic(let config):
            webhookURL = config.webhookUrl
            method = config.method ?? "POST"
            contentType = config.contentType ?? "application/json"
            titleKey = config.titleKey ?? "title"
            messageKey = config.messageKey ?? "message"
            headers = (config.customHeaders ?? [:])
                .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
                .map { NotificationHeaderRow(name: $0.key, value: $0.value) }
            disableTLS = config.disableTls
            successBodyContains = config.successBodyContains ?? ""
            payloadTemplate = config.payloadTemplate ?? ""
            events = EventSubscriptions(events: config.events ?? .defaults)
        }
    }

    func configuration(
        for provider: NotificationProvider,
        supportsPost26Features: Bool = true
    ) -> NotificationConfiguration {
        switch provider {
        case .discord:
            .discord(DiscordNotificationConfiguration(
                webhookId: webhookID,
                token: token.nilIfEmpty,
                username: username.nilIfEmpty,
                avatarUrl: avatarURL.nilIfEmpty,
                events: events.sdkValue
            ))
        case .email:
            .email(EmailNotificationConfiguration(
                smtpHost: host,
                smtpPort: Int(port) ?? 0,
                smtpUsername: smtpUsername,
                smtpPassword: password.nilIfEmpty,
                fromAddress: fromAddress,
                toAddresses: recipients.values,
                tlsMode: EmailTLSMode(rawValue: tlsMode) ?? .starttls,
                authMode: EmailAuthMode(rawValue: authMode) ?? .auto,
                events: events.sdkValue
            ))
        case .telegram:
            .telegram(TelegramNotificationConfiguration(
                botToken: token.nilIfEmpty,
                chatIds: recipients.values,
                preview: preview,
                notification: notification,
                parseMode: parseMode.nilIfEmpty,
                title: title.nilIfEmpty,
                events: events.sdkValue
            ))
        case .signal:
            .signal(SignalNotificationConfiguration(
                host: host,
                port: Int(port) ?? 0,
                user: user.nilIfEmpty,
                password: password.nilIfEmpty,
                token: token.nilIfEmpty,
                source: source,
                recipients: recipients.values,
                disableTls: disableTLS,
                events: events.sdkValue
            ))
        case .slack:
            .slack(SlackNotificationConfiguration(
                token: token.nilIfEmpty,
                botName: botName.nilIfEmpty,
                icon: icon.nilIfEmpty,
                color: color.nilIfEmpty,
                title: title.nilIfEmpty,
                channel: channel.nilIfEmpty,
                threadTs: threadTS.nilIfEmpty,
                events: events.sdkValue
            ))
        case .ntfy:
            .ntfy(NtfyNotificationConfiguration(
                host: host,
                port: Int(port) ?? 0,
                topic: topic,
                username: username.nilIfEmpty,
                password: password.nilIfEmpty,
                title: title.nilIfEmpty,
                priority: priority.nilIfEmpty,
                tags: tags.values.nilIfEmpty,
                icon: icon.nilIfEmpty,
                cache: cache,
                firebase: firebase,
                disableTls: disableTLS,
                disableTlsVerification: disableTLSVerification,
                events: events.sdkValue
            ))
        case .pushover:
            .pushover(PushoverNotificationConfiguration(
                token: token.nilIfEmpty,
                user: user,
                devices: devices.values.nilIfEmpty,
                priority: Int(priority) ?? 0,
                title: title.nilIfEmpty,
                events: events.sdkValue
            ))
        case .gotify:
            .gotify(GotifyNotificationConfiguration(
                host: host,
                port: Int(port),
                token: token.nilIfEmpty,
                path: path.nilIfEmpty,
                priority: Int(priority),
                title: title.nilIfEmpty,
                disableTls: disableTLS,
                insecureSkipVerify: insecureSkipVerify,
                useHeader: useHeader,
                events: events.sdkValue
            ))
        case .matrix:
            .matrix(MatrixNotificationConfiguration(
                host: host,
                port: Int(port),
                rooms: rooms,
                username: username.nilIfEmpty,
                password: password.nilIfEmpty,
                disableTlsVerification: disableTLSVerification,
                events: events.sdkValue
            ))
        case .googlechat:
            .googlechat(GoogleChatNotificationConfiguration(
                webhookUrl: webhookURL.nilIfEmpty,
                events: events.sdkValue
            ))
        case .generic:
            .generic(GenericNotificationConfiguration(
                webhookUrl: webhookURL,
                method: method.nilIfEmpty,
                contentType: supportsPost26Features ? contentType.nilIfEmpty : nil,
                titleKey: supportsPost26Features ? titleKey.nilIfEmpty : nil,
                messageKey: supportsPost26Features ? messageKey.nilIfEmpty : nil,
                customHeaders: headers.dictionary.nilIfEmpty,
                disableTls: disableTLS,
                events: events.sdkValue,
                successBodyContains: supportsPost26Features
                    ? successBodyContains.nilIfEmpty
                    : nil,
                payloadTemplate: supportsPost26Features ? payloadTemplate.nilIfEmpty : nil
            ))
        }
    }

    func isValid(for provider: NotificationProvider) -> Bool {
        switch provider {
        case .discord: !webhookID.isEmpty
        case .email:
            !host.isEmpty && Int(port) != nil && !fromAddress.isEmpty && !recipients.values.isEmpty
        case .telegram: !recipients.values.isEmpty
        case .signal: !host.isEmpty && Int(port) != nil && !source.isEmpty && !recipients.values.isEmpty
        case .slack: !token.isEmpty
        case .ntfy: !host.isEmpty && Int(port) != nil && !topic.isEmpty
        case .pushover: !user.isEmpty
        case .gotify: !host.isEmpty
        case .matrix: !host.isEmpty && !rooms.isEmpty
        case .googlechat: !webhookURL.isEmpty
        case .generic: !webhookURL.isEmpty
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension Array where Element == String {
    var nilIfEmpty: [String]? { isEmpty ? nil : self }
}

private extension Array where Element == NotificationValueRow {
    var values: [String] {
        compactMap { row in
            let value = row.value.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
    }
}

private extension Array where Element == NotificationHeaderRow {
    var dictionary: [String: String] {
        reduce(into: [:]) { result, row in
            let name = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            result[name] = row.value
        }
    }
}

private extension Dictionary {
    var nilIfEmpty: Self? { isEmpty ? nil : self }
}
