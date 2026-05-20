import SwiftUI
import Arcane

extension NotificationProvider: @retroactive Identifiable {
    public var id: String { rawValue }

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

struct EventSubscriptions: Equatable {
    var imageUpdate: Bool = true
    var containerUpdate: Bool = true
    var vulnerabilityFound: Bool = true
    var pruneReport: Bool = false
    var autoHeal: Bool = false

    struct Key: Identifiable {
        let key: String
        let label: String
        var id: String { key }
    }

    static let keys: [Key] = [
        .init(key: "imageUpdate", label: "Image Updates"),
        .init(key: "containerUpdate", label: "Container Updates"),
        .init(key: "vulnerabilityFound", label: "Vulnerabilities"),
        .init(key: "pruneReport", label: "Prune Reports"),
        .init(key: "autoHeal", label: "Auto-Heal"),
    ]

    /// Build an EventSubscriptions from a flat string map (the form's values).
    static func from(_ values: [String: String]) -> EventSubscriptions {
        EventSubscriptions(
            imageUpdate: values["imageUpdate"].map { $0 == "true" } ?? true,
            containerUpdate: values["containerUpdate"].map { $0 == "true" } ?? true,
            vulnerabilityFound: values["vulnerabilityFound"].map { $0 == "true" } ?? true,
            pruneReport: values["pruneReport"].map { $0 == "true" } ?? false,
            autoHeal: values["autoHeal"].map { $0 == "true" } ?? false
        )
    }

    /// Read/write subscript by key string. Used by event toggle bindings.
    subscript(key: String) -> Bool {
        get {
            switch key {
            case "imageUpdate": return imageUpdate
            case "containerUpdate": return containerUpdate
            case "vulnerabilityFound": return vulnerabilityFound
            case "pruneReport": return pruneReport
            case "autoHeal": return autoHeal
            default: return false
            }
        }
        set {
            switch key {
            case "imageUpdate": imageUpdate = newValue
            case "containerUpdate": containerUpdate = newValue
            case "vulnerabilityFound": vulnerabilityFound = newValue
            case "pruneReport": pruneReport = newValue
            case "autoHeal": autoHeal = newValue
            default: break
            }
        }
    }
}

func fieldsForProvider(_ provider: NotificationProvider) -> [ProviderFieldDescriptor] {
    switch provider {
    case .discord:
        return [
            .init(key: "webhookUrl", label: "Webhook URL", placeholder: "https://discord.com/api/webhooks/...", kind: .url, required: true),
            .init(key: "username", label: "Username", placeholder: "Arcane Bot"),
            .init(key: "avatarUrl", label: "Avatar URL", placeholder: "https://...", kind: .url),
        ]
    case .email:
        return [
            .init(key: "smtpHost", label: "SMTP Host", placeholder: "smtp.example.com", required: true),
            .init(key: "smtpPort", label: "SMTP Port", placeholder: "587", kind: .number, required: true, defaultValue: "587"),
            .init(key: "smtpUser", label: "Username", placeholder: "user@example.com", kind: .email),
            .init(key: "smtpPassword", label: "Password", kind: .password),
            .init(key: "from", label: "From Address", placeholder: "arcane@example.com", kind: .email, required: true),
            .init(key: "to", label: "To Address(es)", placeholder: "alerts@example.com (comma-separated for multiple)", required: true),
            .init(key: "tls", label: "Use TLS", kind: .toggle, defaultValue: "true"),
        ]
    case .telegram:
        return [
            .init(key: "botToken", label: "Bot Token", placeholder: "123456:ABC...", kind: .password, required: true),
            .init(key: "chatId", label: "Chat ID", placeholder: "-1001234567890", required: true),
        ]
    case .signal:
        return [
            .init(key: "apiUrl", label: "Signal API URL", placeholder: "https://signal.example.com", kind: .url, required: true),
            .init(key: "number", label: "Signal Number", placeholder: "+1234567890", required: true),
            .init(key: "recipients", label: "Recipients", placeholder: "+1987654321 (comma-separated)", required: true),
        ]
    case .slack:
        return [
            .init(key: "webhookUrl", label: "Webhook URL", placeholder: "https://hooks.slack.com/services/...", kind: .url, required: true),
            .init(key: "channel", label: "Channel Override", placeholder: "#alerts"),
            .init(key: "username", label: "Username Override", placeholder: "Arcane"),
        ]
    case .ntfy:
        return [
            .init(key: "serverUrl", label: "Server URL", placeholder: "https://ntfy.sh", kind: .url, required: true, defaultValue: "https://ntfy.sh"),
            .init(key: "topic", label: "Topic", placeholder: "arcane-alerts", required: true),
            .init(key: "username", label: "Username (optional)"),
            .init(key: "password", label: "Password (optional)", kind: .password),
        ]
    case .pushover:
        return [
            .init(key: "userKey", label: "User Key", required: true),
            .init(key: "apiToken", label: "API Token", kind: .password, required: true),
            .init(key: "priority", label: "Priority", kind: .picker([
                .init(label: "Lowest", value: "-2"),
                .init(label: "Low", value: "-1"),
                .init(label: "Normal", value: "0"),
                .init(label: "High", value: "1"),
                .init(label: "Emergency", value: "2"),
            ]), defaultValue: "0"),
        ]
    case .gotify:
        return [
            .init(key: "serverUrl", label: "Server URL", placeholder: "https://gotify.example.com", kind: .url, required: true),
            .init(key: "token", label: "App Token", kind: .password, required: true),
            .init(key: "priority", label: "Priority", kind: .number, defaultValue: "5"),
        ]
    case .matrix:
        return [
            .init(key: "homeserverUrl", label: "Homeserver URL", placeholder: "https://matrix.org", kind: .url, required: true),
            .init(key: "accessToken", label: "Access Token", kind: .password, required: true),
            .init(key: "roomId", label: "Room ID", placeholder: "!roomId:matrix.org", required: true),
        ]
    case .generic:
        return [
            .init(key: "url", label: "Webhook URL", kind: .url, required: true),
            .init(key: "method", label: "HTTP Method", kind: .picker([
                .init(label: "POST", value: "POST"),
                .init(label: "PUT", value: "PUT"),
                .init(label: "PATCH", value: "PATCH"),
            ]), defaultValue: "POST"),
            .init(key: "customHeaders", label: "Custom Headers", placeholder: "key1:value1, key2:value2", kind: .textarea),
        ]
    }
}

// MARK: - Config Payload helpers

/// Extract a flat `[String: String]` from the SDK's tolerant `[String: JSONValue]`
/// notification config payload. Used by the UI form to populate fields.
func extractConfigValues(_ config: [String: JSONValue]) -> [String: String] {
    var result: [String: String] = [:]
    for (key, value) in config {
        switch value {
        case let .string(s): result[key] = s
        case let .bool(b): result[key] = String(b)
        case let .number(n):
            if n.truncatingRemainder(dividingBy: 1) == 0 {
                result[key] = String(Int(n))
            } else {
                result[key] = String(n)
            }
        default:
            continue
        }
    }
    return result
}

/// Build a SDK-shaped notification config payload (`[String: JSONValue]`) from
/// the form's `[String: String]` field map. Coerces toggle/number kinds.
func buildConfigPayload(_ values: [String: String], provider: NotificationProvider, events: EventSubscriptions) -> [String: JSONValue] {
    var props: [String: JSONValue] = [:]
    let fields = fieldsForProvider(provider)

    for (key, value) in values {
        guard !value.isEmpty else { continue }
        let field = fields.first { $0.key == key }
        switch field?.kind {
        case .toggle:
            props[key] = .bool(value == "true")
        case .number:
            if let intVal = Int(value) {
                props[key] = .number(Double(intVal))
            } else if let dblVal = Double(value) {
                props[key] = .number(dblVal)
            } else {
                props[key] = .string(value)
            }
        default:
            props[key] = .string(value)
        }
    }

    // Event subscription flags
    props["imageUpdate"] = .bool(events.imageUpdate)
    props["containerUpdate"] = .bool(events.containerUpdate)
    props["vulnerabilityFound"] = .bool(events.vulnerabilityFound)
    props["pruneReport"] = .bool(events.pruneReport)
    props["autoHeal"] = .bool(events.autoHeal)

    return props
}
