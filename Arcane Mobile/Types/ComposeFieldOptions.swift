import Foundation

/// Presentation choices supplement fields whose schema describes, but does not enumerate, common values.
nonisolated struct ComposeFieldOptions {
    let values: [String]
    let allowsCustom: Bool

    init(path: [ComposeFieldPathComponent]) {
        let schema = ComposeSchema.value(at: path)
        if let choices = schema?.enumValues, !choices.isEmpty {
            values = choices
            allowsCustom = false
            return
        }
        if path.count == 5, case .key(let root) = path[0], ["services", "jobs"].contains(root),
           Array(path.suffix(3)) == [.key("healthcheck"), .key("test"), .index(0)] {
            values = ["CMD", "CMD-SHELL", "NONE"]
            allowsCustom = false
            return
        }
        let keys = path.map { component -> String in
            switch component {
            case .key(let key): key
            case .index: "[]"
            }
        }
        let match = Self.catalog.first { entry in
            entry.path.count == keys.count && zip(entry.path, keys).allSatisfy { $0 == "*" || $0 == $1 }
        }
        values = match?.values ?? []
        allowsCustom = match?.custom ?? true
    }

    private struct Entry {
        let path: [String]
        let values: [String]
        let custom: Bool
        init(_ path: String, _ values: [String], custom: Bool = false) {
            self.path = path.components(separatedBy: "/")
            self.values = values
            self.custom = custom
        }
    }

    // Closed choices supplement omissions in compose-spec.json. Extensible drivers and
    // parameterized policies retain a custom entry. Paths never match dictionary contents.
    private static let catalog: [Entry] = {
        var result: [Entry] = []
        for root in ["services", "jobs"] {
            let p = root + "/*/"
            result += [
                Entry(p + "cap_add/[]", capabilities),
                Entry(p + "cap_drop/[]", capabilities),
                Entry(p + "stop_signal", signals, custom: true),
                Entry(p + "restart", ["no", "always", "on-failure", "unless-stopped"], custom: true),
                Entry(p + "pull_policy", ["missing", "always", "never", "build", "if_not_present", "refresh", "daily", "weekly"], custom: true),
                Entry(p + "isolation", ["default", "process", "hyperv"]),
                Entry(p + "build/isolation", ["default", "process", "hyperv"]),
                Entry(p + "deploy/mode", ["replicated", "global", "replicated-job", "global-job"]),
                Entry(p + "deploy/endpoint_mode", ["vip", "dnsrr"]),
                Entry(p + "deploy/restart_policy/condition", ["none", "on-failure", "any"]),
                Entry(p + "deploy/update_config/failure_action", ["continue", "pause", "rollback"]),
                Entry(p + "deploy/rollback_config/failure_action", ["continue", "pause"]),
                Entry(p + "ports/[]/protocol", ["tcp", "udp"]),
                Entry(p + "ports/[]/mode", ["host", "ingress"]),
                Entry(p + "volumes/[]/bind/propagation", ["private", "rprivate", "shared", "rshared", "slave", "rslave"]),
                Entry(p + "volumes/[]/consistency", ["consistent", "cached", "delegated"]),
                Entry(p + "devices/[]/permissions", ["rwm", "r", "w", "m", "rw", "rm", "wm"]),
                Entry(p + "env_file/[]/format", ["raw"]),
                Entry(p + "network_mode", ["bridge", "host", "none"], custom: true),
                Entry(p + "ipc", ["private", "shareable", "host", "none"], custom: true),
                Entry(p + "pid", ["host"], custom: true),
                Entry(p + "uts", ["host"]),
                Entry(p + "userns_mode", ["host"]),
                Entry(p + "build/network", ["default", "none", "host"], custom: true),
                Entry(p + "logging/driver", ["local", "json-file", "syslog", "journald", "gelf", "fluentd", "awslogs", "splunk", "etwlogs", "gcplogs", "none"], custom: true)
            ]
        }
        result += [Entry("jobs/*/triggers/schedule/[]/timezone", TimeZone.knownTimeZoneIdentifiers, custom: true)]
        result += [Entry("networks/*/driver", ["bridge", "host", "overlay", "ipvlan", "macvlan", "none"], custom: true)]
        return result
    }()

    // Linux capability names, including Docker's ALL shorthand.
    private static let capabilities = [
        "ALL", "AUDIT_CONTROL", "AUDIT_READ", "AUDIT_WRITE", "BLOCK_SUSPEND", "BPF",
        "CHECKPOINT_RESTORE", "CHOWN", "DAC_OVERRIDE", "DAC_READ_SEARCH", "FOWNER", "FSETID",
        "IPC_LOCK", "IPC_OWNER", "KILL", "LEASE", "LINUX_IMMUTABLE", "MAC_ADMIN", "MAC_OVERRIDE",
        "MKNOD", "NET_ADMIN", "NET_BIND_SERVICE", "NET_BROADCAST", "NET_RAW", "PERFMON", "SETFCAP",
        "SETGID", "SETPCAP", "SETUID", "SYS_ADMIN", "SYS_BOOT", "SYS_CHROOT", "SYS_MODULE", "SYS_NICE",
        "SYS_PACCT", "SYS_PTRACE", "SYS_RAWIO", "SYS_RESOURCE", "SYS_TIME", "SYS_TTY_CONFIG", "SYSLOG", "WAKE_ALARM"
    ]
    private static let signals = [
        "SIGTERM", "SIGINT", "SIGHUP", "SIGQUIT", "SIGKILL", "SIGUSR1", "SIGUSR2", "SIGABRT", "SIGALRM",
        "SIGBUS", "SIGCHLD", "SIGCLD", "SIGCONT", "SIGFPE", "SIGILL", "SIGIO", "SIGIOT", "SIGPIPE", "SIGPOLL",
        "SIGPROF", "SIGPWR", "SIGSEGV", "SIGSTKFLT", "SIGSTOP", "SIGSYS", "SIGTRAP", "SIGTSTP", "SIGTTIN",
        "SIGTTOU", "SIGURG", "SIGVTALRM", "SIGWINCH", "SIGXCPU", "SIGXFSZ", "SIGRTMIN", "SIGRTMAX"
    ] + (1...15).map { "SIGRTMIN+" + String($0) } + (1...14).map { "SIGRTMAX-" + String($0) }

    func label(_ value: String) -> String {
        if Self.capabilities.contains(value) || value.hasPrefix("SIG") || value.contains("/") { return value }
        return switch value {
        case "CMD": "Run command"
        case "CMD-SHELL": "Run in shell"
        case "NONE": "Disable health check"
        case "z": "Shared SELinux label"
        case "Z": "Private SELinux label"
        case "bind": "Host folder"
        case "volume": "Docker volume"
        case "tmpfs": "Temporary memory storage"
        case "tcp": "TCP"
        case "udp": "UDP"
        case "vip": "Virtual IP"
        case "dnsrr": "DNS round-robin"
        case "no": "Never"
        case "on-failure": "On failure"
        case "unless-stopped": "Unless stopped manually"
        case "missing": "Only when missing"
        case "service_started": "Service has started"
        case "service_healthy": "Health check passes"
        case "service_completed_successfully": "Service finishes successfully"
        default: value.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ").capitalized
        }
    }
}
