import Foundation

nonisolated enum ComposeEntryKind: Equatable { case port, mount, keyValue, network }
nonisolated struct ComposeEntrySelection: Identifiable {
    let id = UUID()
    let index: Int?
    let raw: String
}
nonisolated enum ComposeFormError: LocalizedError {
    case duplicate, changed, invalid(String)
    var errorDescription: String? {
        switch self {
        case .duplicate: return "That name already exists."
        case .changed: return "This entry changed. Reopen it before editing."
        case .invalid(let message): return message
        }
    }
}

nonisolated struct ComposeEntryDraft {
    var source = ""
    var target = ""
    var address = ""
    var option = "tcp"
    var readOnly = false
    private var original = ""
    private var longForm = false
    private var originalFields: [String]?
    private var fields: [String] { [source, target, address, option, String(readOnly)] }

    init() {}
    init(raw: String, kind: ComposeEntryKind) throws {
        original = raw
        guard !raw.isEmpty else { return }
        defer { originalFields = fields }
        let document = try ComposeDocument("entry:\n" + raw.split(separator: "\n", omittingEmptySubsequences: false).map { "  " + $0 }.joined(separator: "\n"))
        if let scalar = document.scalar(at: ["entry"]) {
            switch kind {
            case .port:
                guard !scalar.contains("${"), !scalar.contains("[") else { throw ComposeDocumentError.unsupported }
                let proto = scalar.split(separator: "/", omittingEmptySubsequences: false)
                guard proto.count <= 2 else { throw ComposeDocumentError.unsupported }
                if proto.count == 2 { option = String(proto[1]) }
                let parts = proto[0].split(separator: ":", omittingEmptySubsequences: false).map(String.init)
                guard (1...3).contains(parts.count) else { throw ComposeDocumentError.unsupported }
                target = parts.last ?? ""
                if parts.count > 1 { source = parts[parts.count - 2] }
                if parts.count == 3 { address = parts[0] }
            case .mount:
                guard !scalar.contains("${"), !scalar.contains("\\") else { throw ComposeDocumentError.unsupported }
                let parts = scalar.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
                guard (1...3).contains(parts.count) else { throw ComposeDocumentError.unsupported }
                if parts.count == 1 { target = parts[0] }
                else { source = parts[0]; target = parts[1] }
                if parts.count == 3 {
                    guard parts[2] == "ro" || parts[2] == "rw" else { throw ComposeDocumentError.unsupported }
                    readOnly = parts[2] == "ro"
                }
            case .keyValue:
                let parts = scalar.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                source = String(parts[0]); target = parts.count == 2 ? String(parts[1]) : ""
            case .network: source = scalar
            }
        } else {
            guard kind == .port || kind == .mount, document.isEditable(at: ["entry"]) else { throw ComposeDocumentError.unsupported }
            longForm = true
            let fields = kind == .port ? ["target", "published", "host_ip", "protocol"] : ["source", "target", "read_only", "type"]
            for field in fields where document.rawValue(at: ["entry", field]) != nil {
                guard document.scalar(at: ["entry", field]) != nil else { throw ComposeDocumentError.unsupported }
            }
            source = document.scalar(at: ["entry", kind == .port ? "published" : "source"]) ?? ""
            target = document.scalar(at: ["entry", "target"]) ?? ""
            address = document.scalar(at: ["entry", "host_ip"]) ?? ""
            option = document.scalar(at: ["entry", "protocol"]) ?? "tcp"
            if let value = document.scalar(at: ["entry", "read_only"]) {
                guard ["true", "false"].contains(value.lowercased()) else { throw ComposeDocumentError.unsupported }
                readOnly = value.lowercased() == "true"
            }
        }
    }

    func yaml(kind: ComposeEntryKind) throws -> String {
        if originalFields == fields { return original }
        switch kind {
        case .port:
            guard validPort(target), source.isEmpty || validPort(source), ["tcp", "udp", "sctp"].contains(option) else {
                throw ComposeFormError.invalid("Enter ports between 1 and 65535, or a valid port range.")
            }
            guard address.isEmpty || !source.isEmpty else { throw ComposeFormError.invalid("A host address requires a host port.") }
        case .mount:
            guard target.hasPrefix("/"), !target.contains(":"), !source.contains(":") else { throw ComposeFormError.invalid("Enter an absolute container path without colons.") }
        case .keyValue:
            guard !source.isEmpty, !source.contains("="), !source.contains("\n") else { throw ComposeFormError.invalid("Enter a valid name.") }
        case .network:
            guard !source.isEmpty else { throw ComposeFormError.invalid("Enter a network name.") }
        }
        if longForm {
            var result = original
            if kind == .mount, originalFields?[0] != source {
                let document = try ComposeDocument(result)
                let oldType = document.scalar(at: ["type"])
                let newType = source.hasPrefix("/") || source.hasPrefix(".") || source.hasPrefix("~") ? "bind" : "volume"
                if oldType != newType {
                    guard oldType == nil || oldType == "bind" || oldType == "volume",
                          !document.keys(at: []).contains(where: { ["bind", "volume", "tmpfs"].contains($0) }) else {
                        throw ComposeFormError.invalid("This mount has type-specific options. Change its type and source in All settings.")
                    }
                    result = try document.setting(newType, at: ["type"])
                }
            }
            let values: [(String, String)] = kind == .port
                ? [("target", target), ("published", source), ("host_ip", address), ("protocol", option)]
                : [("source", source), ("target", target), ("read_only", readOnly ? "true" : "false")]
            for (key, value) in values {
                let fieldIndex: Int
                switch key {
                case "source", "published": fieldIndex = 0
                case "target": fieldIndex = 1
                case "host_ip": fieldIndex = 2
                case "protocol": fieldIndex = 3
                default: fieldIndex = 4
                }
                if originalFields?[fieldIndex] == value { continue }
                let doc = try ComposeDocument(result)
                if doc.scalar(at: [key]) == value || (value.isEmpty && doc.rawValue(at: [key]) == nil) { continue }
                if value.isEmpty { result = try doc.removing(at: [key]) }
                else { result = try doc.setting(key == "read_only" || key == "target" && kind == .port ? value : ComposeDocument.quoted(value), at: [key]) }
            }
            return result
        }
        let scalar: String
        switch kind {
        case .port:
            scalar = (address.isEmpty ? "" : address + ":") + (source.isEmpty ? "" : source + ":") + target + "/" + option
        case .mount:
            scalar = (source.isEmpty ? "" : source + ":") + target + (readOnly ? ":ro" : "")
        case .keyValue: scalar = source + "=" + target
        case .network: scalar = source
        }
        return ComposeDocument.quoted(scalar)
    }

    private func validPort(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), parts.allSatisfy({ Int($0).map { (1...65535).contains($0) } == true }) else { return false }
        return parts.count == 1 || Int(parts[0])! <= Int(parts[1])!
    }
}
