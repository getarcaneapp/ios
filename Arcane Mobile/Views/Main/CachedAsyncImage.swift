import SwiftUI
import CryptoKit

// MARK: - Shared URL image cache

extension Notification.Name {
    static let imageCacheDidClear = Notification.Name("ImageCacheDidClear")
}

actor ImageCache {
    static let shared = ImageCache()
    nonisolated(unsafe) private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    // Approximate live size, in bytes. NSCache doesn't expose its current cost
    // and may evict silently, so this can drift slightly upward. We reset to 0
    // on `clear()` for accuracy after manual flushes.
    private var approximateBytes: Int = 0

    // Disk tier — survives app termination. iOS may evict the Caches directory
    // under storage pressure; that's the intended semantic.
    private let diskDirectory: URL
    private let diskByteCap: Int = 200 * 1024 * 1024          // 200 MB
    private let diskMaxAge: TimeInterval = 30 * 24 * 60 * 60  // 30 days
    private var didTrim = false

    private init() {
        cache.countLimit = 200
        cache.totalCostLimit = 50 * 1024 * 1024
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        diskDirectory = caches.appendingPathComponent("ImageCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
    }

    nonisolated subscript(url: String) -> UIImage? {
        cache.object(forKey: url as NSString)
    }

    func currentBytes() -> Int {
        approximateBytes + diskBytesOnDisk()
    }

    func clear() {
        cache.removeAllObjects()
        approximateBytes = 0
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: diskDirectory, includingPropertiesForKeys: nil
        ) {
            for url in entries { try? FileManager.default.removeItem(at: url) }
        }
        Task { @MainActor in
            NotificationCenter.default.post(name: .imageCacheDidClear, object: nil)
        }
    }

    func load(_ urlString: String, using fetcher: @escaping (String) async -> Data?) async -> UIImage? {
        if let cached = cache.object(forKey: urlString as NSString) { return cached }
        if let existing = inFlight[urlString] { return await existing.value }

        if !didTrim {
            didTrim = true
            Task.detached(priority: .background) { [weak self] in await self?.trimDiskCache() }
        }

        if let (img, cost) = loadFromDisk(urlString) {
            cache.setObject(img, forKey: urlString as NSString, cost: cost)
            return img
        }

        let task = Task<UIImage?, Never> {
            guard let data = await fetcher(urlString),
                  let img = UIImage(data: data) else { return nil }
            self.cache.setObject(img, forKey: urlString as NSString, cost: data.count)
            self.writeToDisk(urlString, data: data)
            return img
        }
        inFlight[urlString] = task
        let result = await task.value
        inFlight.removeValue(forKey: urlString)
        if let img = result {
            // Approximate live bytes from the decoded pixel buffer
            // (width * height * scale² * 4 bytes/pixel).
            let pixels = img.size.width * img.size.height * img.scale * img.scale
            approximateBytes += Int(pixels) * 4
        }
        return result
    }

    // MARK: - Disk tier

    private func diskURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return diskDirectory.appendingPathComponent(name)
    }

    private func loadFromDisk(_ key: String) -> (UIImage, Int)? {
        let url = diskURL(for: key)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let img = UIImage(data: data) else { return nil }
        // Touch mtime so LRU-by-mtime trim keeps recently-used files alive.
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: url.path
        )
        return (img, data.count)
    }

    private nonisolated func writeToDisk(_ key: String, data: Data) {
        let directory = diskDirectory
        Task.detached(priority: .utility) {
            let digest = SHA256.hash(data: Data(key.utf8))
            let name = digest.map { String(format: "%02x", $0) }.joined()
            let url = directory.appendingPathComponent(name)
            try? data.write(to: url, options: .atomic)
        }
    }

    private nonisolated func diskBytesOnDisk() -> Int {
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

    func trimDiskCache() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .totalFileAllocatedSizeKey]
        guard let entries = try? fm.contentsOfDirectory(
            at: diskDirectory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return }
        let now = Date()
        var alive: [(url: URL, mtime: Date, size: Int)] = []
        for url in entries {
            let v = try? url.resourceValues(forKeys: Set(keys))
            let mtime = v?.contentModificationDate ?? .distantPast
            let size = v?.totalFileAllocatedSize ?? 0
            if now.timeIntervalSince(mtime) > diskMaxAge {
                try? fm.removeItem(at: url)
                continue
            }
            alive.append((url, mtime, size))
        }
        var total = alive.reduce(0) { $0 + $1.size }
        guard total > diskByteCap else { return }
        for entry in alive.sorted(by: { $0.mtime < $1.mtime }) {
            try? fm.removeItem(at: entry.url)
            total -= entry.size
            if total <= diskByteCap { break }
        }
    }
}

// MARK: - Async image view with cache + deduplication

struct CachedAsyncImage: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    let url: String?
    let size: CGFloat
    let fallback: AnyView

    @State private var image: UIImage? = nil
    @State private var lastLoaded: String? = nil

    init(url: String?, size: CGFloat = 36, @ViewBuilder fallback: () -> some View) {
        self.url = url
        self.size = size
        self.fallback = AnyView(fallback())
    }

    var body: some View {
        Group {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(.circle)
            } else {
                fallback
                    .frame(width: size, height: size)
            }
        }
        .onAppear { load() }
        .onChange(of: url) { load() }
        .onReceive(NotificationCenter.default.publisher(for: .imageCacheDidClear)) { _ in
            image = nil
            lastLoaded = nil
            load()
        }
    }

    private func resolvedURL() -> String? {
        guard let urlString = url, !urlString.isEmpty else { return nil }
        var resolved = urlString
        if urlString.hasPrefix("/") {
            let base = manager.serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !base.isEmpty else { return nil }
            resolved = base + urlString
        }
        return Self.preferPNG(resolved)
    }

    // UIImage cannot decode SVG. Convert known CDN SVG paths to their PNG equivalents.
    private static func preferPNG(_ url: String) -> String {
        guard url.hasSuffix(".svg") else { return url }
        // homarr-labs / walkxcode dashboard-icons CDN pattern
        if url.contains("/dashboard-icons/svg/") {
            return url
                .replacingOccurrences(of: "/svg/", with: "/png/")
                .replacingOccurrences(of: ".svg", with: ".png")
        }
        // Generic: try swapping /svg/ → /png/ and .svg → .png for any jsDelivr CDN icon path
        if url.contains("cdn.jsdelivr.net") && url.contains("/svg/") {
            return url
                .replacingOccurrences(of: "/svg/", with: "/png/")
                .replacingOccurrences(of: ".svg", with: ".png")
        }
        return url
    }

    private func load() {
        guard let resolved = resolvedURL(), resolved != lastLoaded else { return }
        if let cached = ImageCache.shared[resolved] {
            image = cached
            lastLoaded = resolved
            return
        }
        lastLoaded = resolved
        Task {
            if let loaded = await ImageCache.shared.load(resolved, using: manager.fetchImageData) {
                image = loaded
            }
        }
    }
}
