import Foundation
import CryptoKit
import Synchronization

// Disk-backed, in-memory-mirrored cache for API GET responses.
// Stale-while-revalidate is implemented in CachedFetch; this layer is
// pure storage + TTL gating + in-flight dedup.
//
// Note: the project defaults to SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor,
// so every type/extension here is explicitly `nonisolated` to avoid
// implicit @MainActor inference on Sendable/Hashable conformances.

nonisolated struct CacheKey: Hashable, Codable, Sendable {
    let serverIdentity: String // canonical scheme + host + effective port + base path
    let userID: String       // currentUser?.id ?? "anon" (multi-account safety)
    let sessionIdentity: String // rotates for every authenticated session
    let envID: String        // active environment raw value
    let pathWithQuery: String

    var allowsDiskPersistence: Bool {
        !pathWithQuery.split(separator: "/").contains("projects")
    }
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

private nonisolated struct HotEntry: Sendable {
    let value: any Sendable
    let storedAt: Date
    var lastAccess: UInt64
}

actor ResponseCache {
    static let shared = ResponseCache()

    private let diskDirectory: URL
    private var hot: [CacheKey: HotEntry] = [:]
    private let hotCapacity = 128
    private var accessTick: UInt64 = 0
    private struct InFlight {
        let id: UUID
        let generation: CacheGeneration
        let task: Task<any Sendable, Error>
    }
    private var inFlight: [CacheKey: InFlight] = [:]
    private var generations: [CacheKey: CacheGeneration] = [:]
    // Disk tier bounds — trimmed lazily on first use per launch (LRU by mtime).
    private let diskByteCap = 50 * 1024 * 1024        // 50 MB
    private let maximumEntryBytes = RemoteDataLimits.maximumResponseBytes
    private let diskMaxAge: TimeInterval = 7 * 24 * 60 * 60  // 7 days
    private var didTrim = false
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let ioQueue: DispatchQueue

    init(directory: URL? = nil, ioQueue: DispatchQueue? = nil) {
        self.ioQueue = ioQueue ?? DispatchQueue(label: "com.arcane.response-cache.io", qos: .utility)
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let legacyDirectories = ["ResponseCache", "ResponseCache-v2"]
            .map { caches.appendingPathComponent($0, isDirectory: true) }
        diskDirectory = directory ?? caches.appendingPathComponent("ResponseCache-v3", isDirectory: true)
        if directory == nil {
            for legacyDirectory in legacyDirectories {
                try? FileManager.default.removeItem(at: legacyDirectory)
            }
        }
        try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        encoder = enc
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        decoder = dec
    }

    // MARK: - Disk Non-Blocking Helpers

    private func readDisk(at url: URL) async -> Data? {
        let entryByteLimit = maximumEntryBytes
        return await withCheckedContinuation { continuation in
            ioQueue.async {
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                      let size = values.fileSize,
                      size <= entryByteLimit else {
                    continuation.resume(returning: nil)
                    return
                }
                let data = try? Data(contentsOf: url, options: .mappedIfSafe)
                continuation.resume(returning: data)
            }
        }
    }

    private func writeDisk(_ data: Data, to url: URL) async {
        guard data.count <= maximumEntryBytes else { return }
        await withCheckedContinuation { continuation in
            ioQueue.async {
                try? data.write(to: url, options: .atomic)
                continuation.resume()
            }
        }
    }

    // MARK: - Hot Cache (LRU-bounded)

    private func nextTick() -> UInt64 {
        accessTick &+= 1
        return accessTick
    }

    private func insertHot(_ key: CacheKey, value: any Sendable, storedAt: Date) {
        hot[key] = HotEntry(value: value, storedAt: storedAt, lastAccess: nextTick())
        guard hot.count > hotCapacity else { return }
        let overflow = hot.count - hotCapacity
        let oldest = hot.sorted { $0.value.lastAccess < $1.value.lastAccess }.prefix(overflow)
        for (staleKey, _) in oldest { hot.removeValue(forKey: staleKey) }
    }

    // MARK: - Read

    func get<T: Codable & Sendable>(_ key: CacheKey, as type: T.Type, ttl: TimeInterval) async -> T? {
        await getEntry(key, as: type, ttl: ttl)?.value
    }

    /// Like `get`, but also reports the entry's age so callers can decide
    /// whether a background revalidation is worth the network round-trip.
    func getEntry<T: Codable & Sendable>(
        _ key: CacheKey, as type: T.Type, ttl: TimeInterval, generation: CacheGeneration? = nil
    ) async -> (value: T, age: TimeInterval)? {
        let generation = generation ?? self.generation(for: key)
        guard generation.isValid else { return nil }
        trimDiskIfNeeded()
        let now = Date()
        if let entry = hot[key] {
            let age = now.timeIntervalSince(entry.storedAt)
            if age > ttl { return nil }
            hot[key]?.lastAccess = nextTick()
            guard let value = entry.value as? T else { return nil }
            return (value, age)
        }
        guard key.allowsDiskPersistence else { return nil }
        let url = diskURL(for: key)
        guard let data = await readDisk(at: url), generation.isValid else { return nil }
        // Cheap header parse first to avoid decoding the full payload on collision/expiry.
        guard let header = try? decoder.decode(EnvelopeHeader.self, from: data),
              header.key == key else { return nil }
        let age = now.timeIntervalSince(header.storedAt)
        if age > ttl { return nil }
        guard let env = try? decoder.decode(ValueEnvelope<T>.self, from: data) else { return nil }
        insertHot(key, value: env.value, storedAt: env.storedAt)
        // Touch mtime so LRU-by-mtime trim keeps recently-read entries alive.
        ioQueue.async {
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()], ofItemAtPath: url.path
            )
        }
        return (env.value, age)
    }

    /// Bounds the disk tier: entries older than `diskMaxAge` are removed, then
    /// the oldest-by-mtime entries go until the total is under `diskByteCap`.
    /// Runs once per launch, entirely on the IO queue.
    private func trimDiskIfNeeded() {
        guard !didTrim else { return }
        didTrim = true
        let directory = diskDirectory
        let byteCap = diskByteCap
        let maxAge = diskMaxAge
        ioQueue.async {
            let fm = FileManager.default
            let keys: [URLResourceKey] = [.contentModificationDateKey, .totalFileAllocatedSizeKey]
            guard let entries = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            ) else { return }
            let now = Date()
            var alive: [(url: URL, mtime: Date, size: Int)] = []
            for url in entries {
                let v = try? url.resourceValues(forKeys: Set(keys))
                let mtime = v?.contentModificationDate ?? .distantPast
                let size = v?.totalFileAllocatedSize ?? 0
                if now.timeIntervalSince(mtime) > maxAge {
                    try? fm.removeItem(at: url)
                    continue
                }
                alive.append((url, mtime, size))
            }
            var total = alive.reduce(0) {
                RemoteDataLimits.saturatingAdd($0, $1.size, maximum: Int.max)
            }
            guard total > byteCap else { return }
            for entry in alive.sorted(by: { $0.mtime < $1.mtime }) {
                try? fm.removeItem(at: entry.url)
                total -= entry.size
                if total <= byteCap { break }
            }
        }
    }

    // MARK: - Write

    @discardableResult
    func set<T: Codable & Sendable>(
        _ key: CacheKey, value: T, generation: CacheGeneration? = nil
    ) async -> Bool {
        let generation = generation ?? self.generation(for: key)
        guard generation.isValid else { return false }
        let storedAt = Date()
        insertHot(key, value: value, storedAt: storedAt)
        guard key.allowsDiskPersistence else { return true }
        let env = ValueEnvelope(key: key, storedAt: storedAt, value: value)
        guard let data = try? encoder.encode(env) else { return generation.isValid }
        let url = diskURL(for: key)
        await writeDisk(data, to: url)
        return generation.isValid
    }

    // MARK: - Invalidation

    func generation(for key: CacheKey) -> CacheGeneration {
        if let generation = generations[key] { return generation }
        let generation = CacheGeneration()
        generations[key] = generation
        return generation
    }

    func invalidate(matching predicate: @Sendable @escaping (CacheKey) -> Bool) async {
        // Retire reads and fetches before the first suspension. A replacement
        // fetch gets its own generation and cannot join a retired request.
        for key in Array(generations.keys) where predicate(key) {
            generations.removeValue(forKey: key)?.invalidate()
            inFlight.removeValue(forKey: key)?.task.cancel()
            hot.removeValue(forKey: key)
        }
        let directory = diskDirectory
        // Keep enumeration and deletion in one serial IO operation. Otherwise
        // invalidation can read an old file and later delete a replacement write.
        await withCheckedContinuation { continuation in
            ioQueue.async {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let entries = (try? FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil
                )) ?? []
                for url in entries {
                    guard let data = try? Data(contentsOf: url),
                          let header = try? decoder.decode(EnvelopeHeader.self, from: data) else {
                        try? FileManager.default.removeItem(at: url)
                        continue
                    }
                    if predicate(header.key) { try? FileManager.default.removeItem(at: url) }
                }
                continuation.resume()
            }
        }
    }

    func invalidateEnvironment(_ envID: String) async {
        await invalidate(matching: { $0.envID == envID })
    }

    func invalidateAll() async {
        await invalidate(matching: { _ in true })
    }

    // MARK: - Dedup

    func coalesce<T: Codable & Sendable>(
        _ key: CacheKey,
        generation: CacheGeneration? = nil,
        work: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        let generation = generation ?? self.generation(for: key)
        guard generation.isValid else { throw CancellationError() }
        let request: InFlight
        if let existing = inFlight[key], existing.generation === generation {
            request = existing
        } else {
            request = InFlight(
                id: UUID(), generation: generation,
                task: Task { try await work() as any Sendable }
            )
            inFlight[key] = request
        }
        defer {
            if inFlight[key]?.id == request.id { inFlight.removeValue(forKey: key) }
        }
        let any = try await request.task.value
        try Task.checkCancellation()
        guard generation.isValid else { throw CancellationError() }
        guard let typed = any as? T else { throw ResponseCacheError.typeMismatch }
        guard await set(key, value: typed, generation: generation) else {
            throw CancellationError()
        }
        return typed
    }

    // MARK: - Disk helpers

    private func diskURL(for key: CacheKey) -> URL {
        let stable = "\(key.serverIdentity)|\(key.userID)|\(key.sessionIdentity)|\(key.envID)|\(key.pathWithQuery)"
        let digest = SHA256.hash(data: Data(stable.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return diskDirectory.appendingPathComponent(name + ".json")
    }

    func diskBytes() async -> Int {
        await withCheckedContinuation { continuation in
            ioQueue.async {
                let fm = FileManager.default
                guard let entries = try? fm.contentsOfDirectory(
                    at: self.diskDirectory,
                    includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
                    options: [.skipsHiddenFiles]
                ) else {
                    continuation.resume(returning: 0)
                    return
                }
                var total = 0
                for url in entries {
                    if let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]),
                       let size = v.totalFileAllocatedSize {
                        total += size
                    }
                }
                continuation.resume(returning: total)
            }
        }
    }
}

/// A shared validity lease also lets MainActor callbacks check freshness without
/// suspending between the check and applying the result.
nonisolated final class CacheGeneration: Sendable {
    private let valid = Mutex(true)

    var isValid: Bool {
        valid.withLock { $0 }
    }

    func invalidate() {
        valid.withLock { $0 = false }
    }
}
