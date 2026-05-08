import SwiftUI

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

    private init() {
        cache.countLimit = 200
        cache.totalCostLimit = 50 * 1024 * 1024
    }

    nonisolated subscript(url: String) -> UIImage? {
        cache.object(forKey: url as NSString)
    }

    func currentBytes() -> Int { approximateBytes }

    func clear() {
        cache.removeAllObjects()
        approximateBytes = 0
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
        Task { @MainActor in
            NotificationCenter.default.post(name: .imageCacheDidClear, object: nil)
        }
    }

    func load(_ urlString: String, using fetcher: @escaping (String) async -> Data?) async -> UIImage? {
        if let cached = cache.object(forKey: urlString as NSString) { return cached }
        if let existing = inFlight[urlString] { return await existing.value }
        let task = Task<UIImage?, Never> {
            guard let data = await fetcher(urlString),
                  let img = UIImage(data: data) else { return nil }
            self.cache.setObject(img, forKey: urlString as NSString, cost: data.count)
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
