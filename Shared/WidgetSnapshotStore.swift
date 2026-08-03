import Foundation
import WidgetKit

/// Atomic JSON load/save of the widget snapshot in the App Group container.
/// The app writes; the widget extension and intents read.
nonisolated enum WidgetSnapshotStore {
    private static let maximumSnapshotBytes = 512 * 1_024
    private static var fileURL: URL? {
        AppGroup.containerURL?.appendingPathComponent("widget-snapshot.json")
    }

    static func load() -> WidgetSnapshot? {
        guard let url = fileURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue <= maximumSnapshotBytes,
              let data = try? Data(contentsOf: url),
              data.count <= maximumSnapshotBytes else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(WidgetSnapshot.self, from: data),
              snapshot.schemaVersion <= WidgetSnapshot.currentSchemaVersion else { return nil }
        if snapshot.serverConfigured {
            guard let configuredURL = AppGroup.defaults?.string(forKey: AppGroup.Keys.serverURL),
                  let configuredOrigin = AppGroup.canonicalServerOrigin(for: configuredURL),
                  snapshot.serverOrigin == configuredOrigin,
                  SharedKeychain.credentialOrigin == configuredOrigin else { return nil }
        }
        return snapshot
    }

    static func save(_ snapshot: WidgetSnapshot) {
        guard let url = fileURL else { return }
        let bounded = snapshot.boundedForPersistence()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(bounded),
              data.count <= maximumSnapshotBytes else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var protectedURL = url
        try? protectedURL.setResourceValues(values)
    }

    /// Saves and asks WidgetCenter to reload — but only when the content
    /// materially changed. Widget reloads are budgeted by the system; timestamp
    /// -only rewrites must not spend it.
    static func saveAndReloadIfChanged(_ snapshot: WidgetSnapshot) {
        let old = load()
        save(snapshot)
        if old == nil || old?.materiallyEquals(snapshot) == false {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}
