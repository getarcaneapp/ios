import Foundation
import Arcane
import Observation

@Observable
final class PinnedItemsStore {
    static let shared = PinnedItemsStore()

    enum ItemKind: String {
        case container, project, volume
    }

    // Bumped whenever any pin changes. Reading this from `pinnedIDs(...)`
    // establishes the @Observable dependency so SwiftUI views re-evaluate
    // their pinned/unpinned partitions after a toggle.
    private(set) var version: Int = 0

    private init() {}

    func pinnedIDs(kind: ItemKind, envID: EnvironmentID) -> Set<String> {
        _ = version
        return loadFromDefaults(key: storageKey(kind: kind, envID: envID))
    }

    func isPinned(_ id: String, kind: ItemKind, envID: EnvironmentID) -> Bool {
        pinnedIDs(kind: kind, envID: envID).contains(id)
    }

    func togglePin(_ id: String, kind: ItemKind, envID: EnvironmentID) {
        let key = storageKey(kind: kind, envID: envID)
        var current = loadFromDefaults(key: key)
        if current.contains(id) {
            current.remove(id)
        } else {
            current.insert(id)
        }
        saveToDefaults(key: key, ids: current)
        version &+= 1
    }

    private func storageKey(kind: ItemKind, envID: EnvironmentID) -> String {
        "arcane.pinned.\(kind.rawValue).\(envID.rawValue)"
    }

    private func loadFromDefaults(key: String) -> Set<String> {
        guard let data = UserDefaults.standard.data(forKey: key),
              let array = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(array)
    }

    private func saveToDefaults(key: String, ids: Set<String>) {
        if ids.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        if let data = try? JSONEncoder().encode(Array(ids)) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
