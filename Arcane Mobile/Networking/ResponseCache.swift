import Foundation
import CryptoKit

// Disk-backed, in-memory-mirrored cache for API GET responses.
// Stale-while-revalidate is implemented in CachedFetch; this layer is
// pure storage + TTL gating + in-flight dedup.
//
// Note: the project defaults to SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor,
// so every type/extension here is explicitly `nonisolated` to avoid
// implicit @MainActor inference on Sendable/Hashable conformances.

nonisolated struct CacheKey: Hashable, Codable, Sendable {
    let serverHost: String   // host portion of manager.serverURL (multi-server safety)
    let userID: String       // currentUser?.id ?? "anon" (multi-account safety)
    let envID: String        // active environment raw value
    let pathWithQuery: String
}

nonisolated enum ResponseCacheError: Error {
    case typeMismatch
}

nonisolated private struct EnvelopeHeader: Decodable {
    let key: CacheKey
    let storedAt: Date
}

nonisolated private struct ValueEnvelope<T: Codable>: Codable {
    let key: CacheKey
    let storedAt: Date
    let value: T
}

private struct HotEntry: @unchecked Sendable {
    let value: any Sendable
    let storedAt: Date
}

actor ResponseCache {
    static let shared = ResponseCache()

    private let diskDirectory: URL
    private var hot: [CacheKey: HotEntry] = [:]
    private var inFlight: [CacheKey: Task<any Sendable, Error>] = [:]
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        diskDirectory = caches.appendingPathComponent("ResponseCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        encoder = enc
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        decoder = dec
    }

    // MARK: - Read

    func get<T: Codable & Sendable>(_ key: CacheKey, as type: T.Type, ttl: TimeInterval) -> T? {
        let now = Date()
        if let entry = hot[key] {
            if now.timeIntervalSince(entry.storedAt) > ttl { return nil }
            return entry.value as? T
        }
        let url = diskURL(for: key)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        // Cheap header parse first to avoid decoding the full payload on collision/expiry.
        guard let header = try? decoder.decode(EnvelopeHeader.self, from: data),
              header.key == key else { return nil }
        if now.timeIntervalSince(header.storedAt) > ttl { return nil }
        guard let env = try? decoder.decode(ValueEnvelope<T>.self, from: data) else { return nil }
        hot[key] = HotEntry(value: env.value, storedAt: env.storedAt)
        return env.value
    }

    // MARK: - Write

    func set<T: Codable & Sendable>(_ key: CacheKey, value: T) {
        let storedAt = Date()
        hot[key] = HotEntry(value: value, storedAt: storedAt)
        let env = ValueEnvelope(key: key, storedAt: storedAt, value: value)
        guard let data = try? encoder.encode(env) else { return }
        let url = diskURL(for: key)
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Invalidation

    func invalidate(matching predicate: @Sendable (CacheKey) -> Bool) {
        for k in hot.keys where predicate(k) { hot.removeValue(forKey: k) }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: diskDirectory, includingPropertiesForKeys: nil
        ) else { return }
        for url in entries {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let header = try? decoder.decode(EnvelopeHeader.self, from: data) else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            if predicate(header.key) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    func invalidateEnvironment(_ envID: String) {
        invalidate(matching: { $0.envID == envID })
    }

    func invalidateAll() {
        hot.removeAll()
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: diskDirectory, includingPropertiesForKeys: nil
        ) {
            for url in entries { try? FileManager.default.removeItem(at: url) }
        }
    }

    // MARK: - Dedup

    func coalesce<T: Codable & Sendable>(
        _ key: CacheKey,
        work: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        if let existing = inFlight[key] {
            let any: any Sendable = try await existing.value
            guard let typed = any as? T else { throw ResponseCacheError.typeMismatch }
            return typed
        }
        let task: Task<any Sendable, Error> = Task { try await work() as any Sendable }
        inFlight[key] = task
        defer { inFlight.removeValue(forKey: key) }
        let any: any Sendable = try await task.value
        guard let typed = any as? T else { throw ResponseCacheError.typeMismatch }
        return typed
    }

    // MARK: - Disk helpers

    private func diskURL(for key: CacheKey) -> URL {
        let stable = "\(key.serverHost)|\(key.userID)|\(key.envID)|\(key.pathWithQuery)"
        let digest = SHA256.hash(data: Data(stable.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return diskDirectory.appendingPathComponent(name + ".json")
    }

    func diskBytes() -> Int {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: diskDirectory,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total = 0
        for url in entries {
            if let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]),
               let size = v.totalFileAllocatedSize {
                total += size
            }
        }
        return total
    }
}
