import SwiftUI
import Arcane
import OpenAPIRuntime

enum NotificationProvider: String, CaseIterable, Identifiable {
    case discord, email, telegram, signal, slack, ntfy, pushover, gotify, matrix, generic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .discord: return "Discord"
        case .email: return "Email"
        case .telegram: return "Telegram"
        case .signal: return "Signal"
        case .slack: return "Slack"
        case .ntfy: return "Ntfy"
        case .pushover: return "Pushover"
        case .gotify: return "Gotify"
        case .matrix: return "Matrix"
        case .generic: return "Generic"
        }
    }

    var systemImage: String {
        switch self {
        case .discord: return "bubble.left.fill"
        case .email: return "envelope.fill"
        case .telegram: return "paperplane.fill"
        case .signal: return "lock.fill"
        case .slack: return "number"
        case .ntfy: return "bell.fill"
        case .pushover: return "iphone.radiowaves.left.and.right"
        case .gotify: return "arrow.up.message.fill"
        case .matrix: return "square.grid.3x3.fill"
        case .generic: return "link"
        }
    }

    var iconColor: Color {
        switch self {
        case .discord: return .indigo
        case .email: return .blue
        case .telegram: return .cyan
        case .signal: return .blue
        case .slack: return .purple
        case .ntfy: return .green
        case .pushover: return .teal
        case .gotify: return .orange
        case .matrix: return .green
        case .generic: return .gray
        }
    }
}

// MARK: - Dynamic Form Field Descriptors

enum ProviderFieldKind {
    case text
    case email
    case password
    case number
    case url
    case toggle
    case textarea
    case picker([PickerOption])
}

struct PickerOption: Identifiable {
    let label: String
    let value: String
    var id: String { value }
}

struct ProviderFieldDescriptor: Identifiable {
    let key: String
    let label: String
    let placeholder: String
    let kind: ProviderFieldKind
    let required: Bool
    let defaultValue: String

    var id: String { key }

    init(key: String, label: String, placeholder: String = "", kind: ProviderFieldKind = .text, required: Bool = false, defaultValue: String = "") {
        self.key = key
        self.label = label
        self.placeholder = placeholder
        self.kind = kind
        self.required = required
        self.defaultValue = defaultValue
    }
}

// MARK: - Event Subscriptions

struct EventSubscriptions: Equatable {
    var imageUpdate: Bool = true
    var containerUpdate: Bool = true
    var vulnerabilityFound: Bool = true
    var pruneReport: Bool = true
    var autoHeal: Bool = true

    static let keys: [(key: String, label: String)] = [
        ("eventImageUpdate", "Image Updates"),
        ("eventContainerUpdate", "Container Updates"),
        ("eventVulnerabilityFound", "Vulnerability Found"),
        ("eventPruneReport", "Prune Reports"),
        ("eventAutoHeal", "Auto-Heal"),
    ]

    func toDict() -> [String: String] {
        [
            "eventImageUpdate": String(imageUpdate),
            "eventContainerUpdate": String(containerUpdate),
            "eventVulnerabilityFound": String(vulnerabilityFound),
            "eventPruneReport": String(pruneReport),
            "eventAutoHeal": String(autoHeal),
        ]
    }

    static func from(_ dict: [String: String]) -> EventSubscriptions {
        EventSubscriptions(
            imageUpdate: dict["eventImageUpdate"] == "true",
            containerUpdate: dict["eventContainerUpdate"] == "true",
            vulnerabilityFound: dict["eventVulnerabilityFound"] == "true",
            pruneReport: dict["eventPruneReport"] == "true",
            autoHeal: dict["eventAutoHeal"] == "true"
        )
    }
}

// MARK: - Provider Field Schemas

func fieldsForProvider(_ provider: NotificationProvider) -> [ProviderFieldDescriptor] {
    switch provider {
    case .discord:
        return [
            .init(key: "webhookId", label: "Webhook ID", placeholder: "Discord webhook ID", required: true),
            .init(key: "token", label: "Token", placeholder: "Discord webhook token", kind: .password, required: true),
            .init(key: "username", label: "Username", placeholder: "Bot username"),
            .init(key: "avatarUrl", label: "Avatar URL", placeholder: "https://example.com/avatar.png", kind: .url),
        ]
    case .email:
        return [
            .init(key: "smtpHost", label: "SMTP Host", placeholder: "smtp.example.com", required: true),
            .init(key: "smtpPort", label: "SMTP Port", placeholder: "587", kind: .number, required: true, defaultValue: "587"),
            .init(key: "smtpUsername", label: "Username", placeholder: "user@example.com"),
            .init(key: "smtpPassword", label: "Password", kind: .password),
            .init(key: "fromAddress", label: "From Address", placeholder: "noreply@example.com", kind: .email, required: true),
            .init(key: "toAddresses", label: "To Addresses", placeholder: "user@example.com, admin@example.com", kind: .textarea, required: true),
            .init(key: "tlsMode", label: "TLS Mode", kind: .picker([
                .init(label: "None", value: "none"),
                .init(label: "STARTTLS", value: "starttls"),
                .init(label: "SSL", value: "ssl"),
            ]), required: true, defaultValue: "starttls"),
        ]
    case .telegram:
        return [
            .init(key: "botToken", label: "Bot Token", kind: .password, required: true),
            .init(key: "chatIds", label: "Chat IDs", placeholder: "123456789, -100123456", kind: .textarea, required: true),
            .init(key: "title", label: "Title", placeholder: "Arcane"),
            .init(key: "preview", label: "Link Preview", kind: .toggle, defaultValue: "true"),
            .init(key: "notification", label: "Send Notification Sound", kind: .toggle, defaultValue: "true"),
        ]
    case .signal:
        return [
            .init(key: "host", label: "Host", placeholder: "localhost", required: true, defaultValue: "localhost"),
            .init(key: "port", label: "Port", placeholder: "8080", kind: .number, required: true, defaultValue: "8080"),
            .init(key: "user", label: "Username"),
            .init(key: "password", label: "Password", kind: .password),
            .init(key: "token", label: "Token", placeholder: "Auth token (alternative to user/pass)", kind: .password),
            .init(key: "source", label: "Source Number", placeholder: "+1234567890", required: true),
            .init(key: "recipients", label: "Recipients", placeholder: "+1234567890, +0987654321", kind: .textarea, required: true),
            .init(key: "disableTls", label: "Disable TLS", kind: .toggle, defaultValue: "false"),
        ]
    case .slack:
        return [
            .init(key: "token", label: "Token", kind: .password, required: true),
            .init(key: "botName", label: "Bot Name", placeholder: "Arcane", defaultValue: "Arcane"),
            .init(key: "icon", label: "Icon", placeholder: ":robot_face:"),
            .init(key: "color", label: "Color", placeholder: "#36a64f"),
            .init(key: "title", label: "Title"),
            .init(key: "channel", label: "Channel", placeholder: "#general"),
            .init(key: "threadTs", label: "Thread Timestamp"),
        ]
    case .ntfy:
        return [
            .init(key: "host", label: "Host", placeholder: "ntfy.sh", required: true, defaultValue: "ntfy.sh"),
            .init(key: "port", label: "Port", placeholder: "0", kind: .number, defaultValue: "0"),
            .init(key: "topic", label: "Topic", placeholder: "arcane-notifications", required: true),
            .init(key: "username", label: "Username"),
            .init(key: "password", label: "Password", kind: .password),
            .init(key: "title", label: "Title"),
            .init(key: "priority", label: "Priority", kind: .picker([
                .init(label: "Min", value: "min"),
                .init(label: "Low", value: "low"),
                .init(label: "Default", value: "default"),
                .init(label: "High", value: "high"),
                .init(label: "Max", value: "max"),
            ]), defaultValue: "default"),
            .init(key: "tags", label: "Tags", placeholder: "tag1, tag2", kind: .textarea),
            .init(key: "icon", label: "Icon URL", placeholder: "https://example.com/icon.png"),
            .init(key: "cache", label: "Cache Messages", kind: .toggle, defaultValue: "true"),
            .init(key: "firebase", label: "Firebase Delivery", kind: .toggle, defaultValue: "true"),
            .init(key: "disableTlsVerification", label: "Disable TLS Verification", kind: .toggle, defaultValue: "false"),
        ]
    case .pushover:
        return [
            .init(key: "token", label: "API Token", kind: .password, required: true),
            .init(key: "user", label: "User Key", required: true),
            .init(key: "devices", label: "Devices", placeholder: "device1, device2", kind: .textarea),
            .init(key: "priority", label: "Priority", kind: .picker([
                .init(label: "Lowest (-2)", value: "-2"),
                .init(label: "Low (-1)", value: "-1"),
                .init(label: "Normal (0)", value: "0"),
                .init(label: "High (1)", value: "1"),
                .init(label: "Emergency (2)", value: "2"),
            ]), defaultValue: "0"),
            .init(key: "title", label: "Title"),
        ]
    case .gotify:
        return [
            .init(key: "host", label: "Host", placeholder: "gotify.example.com", required: true),
            .init(key: "port", label: "Port", kind: .number),
            .init(key: "token", label: "App Token", kind: .password, required: true),
            .init(key: "path", label: "Path"),
            .init(key: "priority", label: "Priority", kind: .picker(
                (0...10).map { .init(label: "\($0)", value: "\($0)") }
            ), defaultValue: "0"),
            .init(key: "title", label: "Title"),
            .init(key: "disableTls", label: "Disable TLS", kind: .toggle, defaultValue: "false"),
        ]
    case .matrix:
        return [
            .init(key: "host", label: "Homeserver", placeholder: "matrix.org", required: true),
            .init(key: "port", label: "Port", kind: .number),
            .init(key: "rooms", label: "Rooms", placeholder: "!room:matrix.org"),
            .init(key: "username", label: "Username"),
            .init(key: "password", label: "Password", kind: .password),
            .init(key: "disableTlsVerification", label: "Disable TLS Verification", kind: .toggle, defaultValue: "false"),
        ]
    case .generic:
        return [
            .init(key: "webhookUrl", label: "Webhook URL", placeholder: "https://example.com/webhook", kind: .url, required: true),
            .init(key: "method", label: "HTTP Method", defaultValue: "POST"),
            .init(key: "contentType", label: "Content Type", defaultValue: "application/json"),
            .init(key: "titleKey", label: "Title Key", defaultValue: "title"),
            .init(key: "messageKey", label: "Message Key", defaultValue: "message"),
            .init(key: "customHeaders", label: "Custom Headers", placeholder: "key1:value1, key2:value2", kind: .textarea),
        ]
    }
}

// MARK: - OpenAPIValueContainer Conversion Helpers

func extractConfigValues(_ config: Components.Schemas.NotificationResponse.ConfigPayload) -> [String: String] {
    var result: [String: String] = [:]
    for (key, container) in config.additionalProperties {
        if let str = container.value as? String {
            result[key] = str
        } else if let bool = container.value as? Bool {
            result[key] = String(bool)
        } else if let num = container.value as? Int {
            result[key] = String(num)
        } else if let num = container.value as? Double {
            if num.truncatingRemainder(dividingBy: 1) == 0 {
                result[key] = String(Int(num))
            } else {
                result[key] = String(num)
            }
        }
    }
    return result
}

func buildConfigPayload(_ values: [String: String], provider: NotificationProvider, events: EventSubscriptions) -> Components.Schemas.NotificationUpdate.ConfigPayload {
    var props: [String: OpenAPIValueContainer] = [:]
    let fields = fieldsForProvider(provider)

    for (key, value) in values {
        guard !value.isEmpty else { continue }
        let field = fields.first { $0.key == key }
        switch field?.kind {
        case .toggle:
            props[key] = try! OpenAPIValueContainer(unvalidatedValue: value == "true")
        case .number:
            if let intVal = Int(value) {
                props[key] = try! OpenAPIValueContainer(unvalidatedValue: intVal)
            } else {
                props[key] = try! OpenAPIValueContainer(unvalidatedValue: value)
            }
        default:
            props[key] = try! OpenAPIValueContainer(unvalidatedValue: value)
        }
    }

    let eventDict = events.toDict()
    for (key, value) in eventDict {
        props[key] = try! OpenAPIValueContainer(unvalidatedValue: value == "true")
    }

    return .init(additionalProperties: props)
}
