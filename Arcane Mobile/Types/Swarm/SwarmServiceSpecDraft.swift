import Arcane
import Foundation

/// Editable view of a Docker swarm `ServiceSpec`. Edits are applied back onto
/// the original spec JSON so fields the form doesn't expose (resources,
/// placement, update config, secrets, …) survive a round trip.
nonisolated struct SwarmServiceSpecDraft: Equatable, Sendable {
    enum Mode: String, CaseIterable, Sendable {
        case replicated
        case global
        /// ReplicatedJob / GlobalJob: shown but not editable.
        case job
    }

    struct Port: Identifiable, Equatable, Sendable {
        var id = UUID()
        var target = ""
        var published = ""
        var proto = "tcp"
    }

    struct Mount: Identifiable, Equatable, Sendable {
        var id = UUID()
        var type = "volume"
        var source = ""
        var target = ""
        var readOnly = false
    }

    struct Pair: Identifiable, Equatable, Sendable {
        var id = UUID()
        var key = ""
        var value = ""
    }

    var name = ""
    var image = ""
    var mode = Mode.replicated
    var replicas = 1
    var ports: [Port] = []
    var env: [Pair] = []
    var mounts: [Mount] = []
    var labels: [Pair] = []
    var command = ""
    var args = ""
    var workingDir = ""
    var user = ""
    var hostname = ""

    init() {}

    init(spec: JSONValue) {
        let object = spec.swarmObject ?? [:]
        let containerSpec = object["TaskTemplate"]?["ContainerSpec"]?.swarmObject ?? [:]
        name = object["Name"]?.swarmString ?? ""
        image = containerSpec["Image"]?.swarmString ?? ""

        let modeObject = object["Mode"]?.swarmObject ?? [:]
        if let replicated = modeObject["Replicated"] {
            mode = .replicated
            if case .number(let count)? = replicated["Replicas"], count.isFinite { replicas = Int(count) }
        } else if modeObject["Global"] != nil {
            mode = .global
        } else if modeObject["ReplicatedJob"] != nil || modeObject["GlobalJob"] != nil {
            mode = .job
        }

        ports = (object["EndpointSpec"]?["Ports"]?.swarmArray ?? []).map { port in
            Port(
                target: Self.numberString(port["TargetPort"]),
                published: Self.numberString(port["PublishedPort"]),
                proto: port["Protocol"]?.swarmString ?? "tcp"
            )
        }
        env = (containerSpec["Env"]?.swarmArray ?? []).compactMap(\.swarmString).map { entry in
            let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return Pair(key: String(parts[0]), value: parts.count > 1 ? String(parts[1]) : "")
        }
        mounts = (containerSpec["Mounts"]?.swarmArray ?? []).map { mount in
            var readOnly = false
            if case .bool(let value)? = mount["ReadOnly"] { readOnly = value }
            return Mount(
                type: mount["Type"]?.swarmString ?? "volume",
                source: mount["Source"]?.swarmString ?? "",
                target: mount["Target"]?.swarmString ?? "",
                readOnly: readOnly
            )
        }
        labels = (object["Labels"]?.swarmObject ?? [:])
            .sorted { $0.key < $1.key }
            .map { Pair(key: $0.key, value: $0.value.swarmString ?? "") }
        command = Self.joinArguments(containerSpec["Command"])
        args = Self.joinArguments(containerSpec["Args"])
        workingDir = containerSpec["Dir"]?.swarmString ?? ""
        user = containerSpec["User"]?.swarmString ?? ""
        hostname = containerSpec["Hostname"]?.swarmString ?? ""
    }

    var isValid: Bool {
        !name.swarmTrimmed.isEmpty && !image.swarmTrimmed.isEmpty
    }

    /// Writes the draft onto `original` (or a fresh spec), keeping unknown keys.
    func apply(to original: JSONValue?) -> JSONValue {
        var object = original?.swarmObject ?? [:]
        object["Name"] = .string(name.swarmTrimmed)
        object["Labels"] = Self.object(from: labels)

        var taskTemplate = object["TaskTemplate"]?.swarmObject ?? [:]
        var containerSpec = taskTemplate["ContainerSpec"]?.swarmObject ?? [:]
        containerSpec["Image"] = .string(image.swarmTrimmed)
        Self.set(&containerSpec, "Command", Self.arrayValue(Self.splitArguments(command)))
        Self.set(&containerSpec, "Args", Self.arrayValue(Self.splitArguments(args)))
        let envEntries = env.filter { !$0.key.swarmTrimmed.isEmpty }.map { "\($0.key.swarmTrimmed)=\($0.value)" }
        Self.set(&containerSpec, "Env", Self.arrayValue(envEntries))
        Self.set(&containerSpec, "Dir", Self.optionalString(workingDir))
        Self.set(&containerSpec, "User", Self.optionalString(user))
        Self.set(&containerSpec, "Hostname", Self.optionalString(hostname))

        let originalMounts = containerSpec["Mounts"]?.swarmArray ?? []
        let mountValues: [JSONValue] = mounts.filter { !$0.target.swarmTrimmed.isEmpty }.map { mount in
            let target = mount.target.swarmTrimmed
            var entry = originalMounts.first { $0["Target"]?.swarmString == target }?.swarmObject ?? [:]
            entry["Type"] = .string(mount.type)
            entry["Source"] = .string(mount.source.swarmTrimmed)
            entry["Target"] = .string(target)
            entry["ReadOnly"] = .bool(mount.readOnly)
            return .object(entry)
        }
        Self.set(&containerSpec, "Mounts", mountValues.isEmpty ? nil : .array(mountValues))
        taskTemplate["ContainerSpec"] = .object(containerSpec)
        object["TaskTemplate"] = .object(taskTemplate)

        switch mode {
        case .replicated:
            object["Mode"] = .object(["Replicated": .object(["Replicas": .number(Double(max(0, replicas)))])])
        case .global:
            object["Mode"] = .object(["Global": .object([:])])
        case .job:
            break
        }

        var endpoint = object["EndpointSpec"]?.swarmObject ?? [:]
        let originalPorts = endpoint["Ports"]?.swarmArray ?? []
        let portValues: [JSONValue] = ports.compactMap { port in
            guard let target = UInt32(port.target.swarmTrimmed) else { return nil }
            var entry =
                originalPorts.first {
                    Self.numberString($0["TargetPort"]) == String(target)
                        && ($0["Protocol"]?.swarmString ?? "tcp") == port.proto
                }?.swarmObject ?? [:]
            entry["Protocol"] = .string(port.proto)
            entry["TargetPort"] = .number(Double(target))
            if let published = UInt32(port.published.swarmTrimmed) {
                entry["PublishedPort"] = .number(Double(published))
            } else {
                entry.removeValue(forKey: "PublishedPort")
            }
            return .object(entry)
        }
        Self.set(&endpoint, "Ports", portValues.isEmpty ? nil : .array(portValues))
        object["EndpointSpec"] = .object(endpoint)
        return .object(object)
    }

    // MARK: - Helpers

    private static func set(_ object: inout [String: JSONValue], _ key: String, _ value: JSONValue?) {
        if let value { object[key] = value } else { object.removeValue(forKey: key) }
    }

    private static func optionalString(_ value: String) -> JSONValue? {
        value.swarmTrimmed.isEmpty ? nil : .string(value.swarmTrimmed)
    }

    private static func object(from pairs: [Pair]) -> JSONValue {
        var result: [String: JSONValue] = [:]
        for pair in pairs where !pair.key.swarmTrimmed.isEmpty {
            result[pair.key.swarmTrimmed] = .string(pair.value)
        }
        return .object(result)
    }

    private static func arrayValue(_ strings: [String]) -> JSONValue? {
        strings.isEmpty ? nil : .array(strings.map { .string($0) })
    }

    static func numberString(_ value: JSONValue?) -> String {
        guard case .number(let number)? = value, number.isFinite else { return "" }
        return String(Int64(number))
    }

    /// Joins argv for display, quoting arguments that contain whitespace.
    static func joinArguments(_ value: JSONValue?) -> String {
        (value?.swarmArray ?? []).compactMap(\.swarmString).map { argument in
            argument.contains(where: \.isWhitespace) || argument.isEmpty
                ? "\"\(argument.replacingOccurrences(of: "\"", with: "\\\""))\"" : argument
        }
        .joined(separator: " ")
    }

    /// Splits a command line into argv, honouring single and double quotes.
    static func splitArguments(_ line: String) -> [String] {
        var arguments: [String] = []
        var current = ""
        var quote: Character?
        var hasToken = false
        var escaping = false
        for character in line {
            if escaping {
                current.append(character)
                escaping = false
                continue
            }
            if character == "\\", quote != "'" {
                escaping = true
                hasToken = true
                continue
            }
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                hasToken = true
            } else if character.isWhitespace {
                if hasToken {
                    arguments.append(current)
                    current = ""
                    hasToken = false
                }
            } else {
                current.append(character)
                hasToken = true
            }
        }
        if hasToken { arguments.append(current) }
        return arguments
    }
}

extension String {
    nonisolated fileprivate var swarmTrimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
