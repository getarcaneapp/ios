import Foundation

/// Presentation only; source paths and values retain their original spelling.
nonisolated enum ComposeDisplayText {
    static func title(_ value: String) -> String {
        if value == "x-arcane" { return "Arcane Metadata" }
        let acronyms = ["dns": "DNS", "url": "URL", "urls": "URLs", "ip": "IP", "ipv4": "IPv4", "ipv6": "IPv6", "pid": "PID", "ipc": "IPC", "cpu": "CPU", "cpus": "CPUs", "io": "IO", "mac": "MAC"]
        return value.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { acronyms[$0.lowercased()] ?? $0.capitalized }
            .joined(separator: " ")
    }
}
