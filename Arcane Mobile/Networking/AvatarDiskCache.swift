import CryptoKit
import Foundation

/// The signed-in user's profile picture, kept on disk so it shows instantly on
/// launch instead of downloading every session. Keyed by server, user, and the
/// account's `updatedAt`, so an account change misses the cache; entries also
/// expire after a day so a Gravatar change (which doesn't touch the account)
/// still appears.
nonisolated enum AvatarDiskCache {
    static let maximumAge: TimeInterval = 24 * 60 * 60

    private static var directory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Avatars", isDirectory: true)
    }

    private static func fileURL(for key: String) -> URL? {
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory?.appendingPathComponent(name)
    }

    @concurrent static func load(key: String) async -> Data? {
        guard let url = fileURL(for: key),
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate,
            Date().timeIntervalSince(modified) < maximumAge
        else { return nil }
        return try? Data(contentsOf: url)
    }

    @concurrent static func save(_ data: Data, key: String) async {
        guard let directory, let url = fileURL(for: key) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    @concurrent static func clear() async {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    @concurrent static func diskBytes() async -> Int {
        guard let directory,
            let entries = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
        else { return 0 }
        return entries.reduce(0) { total, url in
            total + ((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
    }
}
