import SwiftUI
import CryptoKit
import ImageIO

// MARK: - Shared URL image cache

extension Notification.Name {
    nonisolated static let imageCacheDidClear = Notification.Name("ImageCacheDidClear")
}

actor ImageCache {
    static let shared = ImageCache()
    nonisolated(unsafe) private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    // Disk tier — survives app termination. iOS may evict the Caches directory
    // under storage pressure; that's the intended semantic.
    private let diskDirectory: URL
    private let diskByteCap: Int = 200 * 1024 * 1024          // 200 MB
    private let diskMaxAge: TimeInterval = 30 * 24 * 60 * 60  // 30 days
    private var didTrim = false

    private init() {
        cache.countLimit = 200
        cache.totalCostLimit = 50 * 1024 * 1024
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        diskDirectory = caches.appendingPathComponent("ImageCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
    }

    nonisolated subscript(url: String) -> UIImage? {
        cache.object(forKey: url as NSString)
    }

    nonisolated subscript(url: String, maxPixelSize maxPixel: Int) -> UIImage? {
        cache.object(forKey: Self.memoryKey(url: url, maxPixel: maxPixel) as NSString)
    }

    private static func memoryKey(url: String, maxPixel: Int) -> String {
        maxPixel > 0 ? "\(url)|\(maxPixel)" : url
    }

    func diskBytes() -> Int {
        diskBytesOnDisk()
    }

    func clear() {
        cache.removeAllObjects()
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: diskDirectory, includingPropertiesForKeys: nil
        ) {
            for url in entries { try? FileManager.default.removeItem(at: url) }
        }
        NotificationCenter.default.post(name: .imageCacheDidClear, object: nil)
    }

    func load(_ urlString: String, maxPixelSize: Int = 0, using fetcher: @escaping @Sendable (String) async -> Data?) async -> UIImage? {
        let keyString = Self.memoryKey(url: urlString, maxPixel: maxPixelSize)
        if let cached = cache.object(forKey: keyString as NSString) { return cached }
        if let existing = inFlight[keyString] { return await existing.value }

        if !didTrim {
            didTrim = true
            Task.detached(priority: .background) { [weak self] in self?.trimDiskCache() }
        }

        // Disk read, network fetch, and decode all run detached: doing them on
        // the actor executor serialized every concurrent image load behind
        // synchronous disk I/O. The actor only coordinates in-flight dedup.
        let task = Task.detached(priority: .userInitiated) { () -> UIImage? in
            if let (img, cost) = self.loadFromDisk(urlString, maxPixelSize: maxPixelSize) {
                self.cache.setObject(img, forKey: keyString as NSString, cost: cost)
                return img
            }
            guard let data = await fetcher(urlString) else { return nil }
            self.writeToDisk(urlString, data: data)
            guard let img = Self.decode(data: data, maxPixelSize: maxPixelSize) else { return nil }
            let cost = Self.approximateCost(of: img)
            self.cache.setObject(img, forKey: keyString as NSString, cost: cost)
            return img
        }
        inFlight[keyString] = task
        let result = await task.value
        inFlight.removeValue(forKey: keyString)
        return result
    }

    private static func decode(data: Data, maxPixelSize: Int) -> UIImage? {
        guard maxPixelSize > 0 else { return UIImage(data: data) }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return UIImage(data: data)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cgImage)
    }

    private static func approximateCost(of img: UIImage) -> Int {
        let pixels = img.size.width * img.size.height * img.scale * img.scale
        return Int(pixels) * 4
    }

    // MARK: - Disk tier

    private nonisolated func diskURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return diskDirectory.appendingPathComponent(name)
    }

    private nonisolated func loadFromDisk(_ key: String, maxPixelSize: Int) -> (UIImage, Int)? {
        let url = diskURL(for: key)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let img = Self.decode(data: data, maxPixelSize: maxPixelSize) else { return nil }
        // Touch mtime so LRU-by-mtime trim keeps recently-used files alive.
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: url.path
        )
        return (img, Self.approximateCost(of: img))
    }

    private nonisolated func writeToDisk(_ key: String, data: Data) {
        try? data.write(to: diskURL(for: key), options: .atomic)
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

    nonisolated func trimDiskCache() {
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

/// Identity for `CachedAsyncImage`'s load task. Combines the requested URL with
/// a reload token so clearing the shared cache forces a reload even when `url`
/// is unchanged.
private struct CachedImageLoadID: Hashable {
    let url: String?
    let token: Int
}

struct CachedAsyncImage<Fallback: View>: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    let url: String?
    let size: CGFloat
    let fallback: Fallback

    @State private var image: UIImage? = nil
    /// Bumped when the shared cache is cleared, to force `.task(id:)` to re-run
    /// even though `url` hasn't changed.
    @State private var reloadToken = 0

    init(url: String?, size: CGFloat = 36, @ViewBuilder fallback: () -> Fallback) {
        self.url = url
        self.size = size
        self.fallback = fallback()
    }

    var body: some View {
        Group {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
            } else {
                fallback
                    .frame(width: size, height: size)
            }
        }
        .task(id: CachedImageLoadID(url: url, token: reloadToken)) {
            await loadImage()
        }
        .onReceive(NotificationCenter.default.publisher(for: .imageCacheDidClear)) { _ in
            reloadToken += 1
        }
    }

    private func resolvedURL() -> String? {
        guard let urlString = url, !urlString.isEmpty else { return nil }
        let resolved: String
        if urlString.hasPrefix("/") {
            guard let base = manager.parsedServerURL,
                  let combined = URL(string: urlString, relativeTo: base)?.absoluteURL
            else { return nil }
            resolved = combined.absoluteString
        } else {
            resolved = urlString
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

    private var maxPixelSize: Int {
        let scale = UITraitCollection.current.displayScale
        let effectiveScale = scale > 0 ? scale : 3
        return Int((size * effectiveScale).rounded(.up))
    }

    /// Loads the resolved image into `image`. Runs inside `.task(id:)`, so it is
    /// cancelled automatically when the row scrolls off-screen or `url` changes.
    /// The post-await cancellation check guards against a stale write if the URL
    /// changed while a fetch was in flight.
    private func loadImage() async {
        image = nil
        guard let resolved = resolvedURL() else { return }
        let maxPixel = maxPixelSize
        if let cached = ImageCache.shared[resolved, maxPixelSize: maxPixel] {
            image = cached
            return
        }
        let loaded = await ImageCache.shared.load(resolved, maxPixelSize: maxPixel, using: manager.fetchImageData)
        if Task.isCancelled { return }
        if let loaded { image = loaded }
    }
}
