import Foundation
import Observation

@MainActor @Observable
final class EnvironmentColorStore {
    static let shared = EnvironmentColorStore()
    private let defaults: UserDefaults
    private var colors: [String: String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        colors = defaults.dictionary(forKey: "arcane.environmentColors") as? [String: String] ?? [:]
    }

    private func key(server: String, environmentID: String) -> String {
        let normalized = (try? ConnectionProfileSync.normalizedServerURL(server)) ?? server
        return normalized + "\n" + environmentID
    }

    func hex(server: String, environmentID: String) -> String? {
        colors[key(server: server, environmentID: environmentID)]
    }

    func assignDefaults(server: String, environmentIDs: [String]) {
        let prefix = key(server: server, environmentID: "")
        var used = Set<String>()
        // Include saved environments that are temporarily absent, so their colors stay reserved.
        let keys = Set(colors.keys.filter { $0.hasPrefix(prefix) } + environmentIDs.map { key(server: server, environmentID: $0) })
        for key in keys.sorted() {
            if let existing = colors[key]?.uppercased(), used.insert(existing).inserted {
                colors[key] = existing
            } else {
                let color = availableColor(excluding: used)
                colors[key] = color
                used.insert(color)
            }
        }
        defaults.set(colors, forKey: "arcane.environmentColors")
    }

    func isAvailable(_ hex: String, server: String, environmentID: String) -> Bool {
        let target = key(server: server, environmentID: environmentID)
        let prefix = key(server: server, environmentID: "")
        return !colors.contains { $0.key.hasPrefix(prefix) && $0.key != target && $0.value.uppercased() == hex.uppercased() }
    }

    @discardableResult
    func set(_ hex: String?, server: String, environmentID: String) -> Bool {
        let target = key(server: server, environmentID: environmentID)
        let prefix = key(server: server, environmentID: "")
        let used = Set(colors.filter { $0.key.hasPrefix(prefix) && $0.key != target }.values.map { $0.uppercased() })
        let value = hex?.uppercased() ?? availableColor(excluding: used)
        guard !used.contains(value) else { return false }
        colors[target] = value
        defaults.set(colors, forKey: "arcane.environmentColors")
        return true
    }

    private func availableColor(excluding used: Set<String>) -> String {
        let palette = ["#2680C2", "#D06820", "#289B66", "#9657CA", "#C64574", "#168D97", "#AB841A", "#646DD6", "#BB5142", "#678B36", "#A453A5", "#477D91"]
        if let color = palette.first(where: { !used.contains($0) }) { return color }
        // Walk the RGB space without repeating colors when the initial palette is exhausted.
        for index in 1...0xFFFFFF {
            let value = (index * 0x9E3779) & 0xFFFFFF
            let color = String(format: "#%06X", value)
            if !used.contains(color) { return color }
        }
        preconditionFailure("Environment color space exhausted")
    }
}
