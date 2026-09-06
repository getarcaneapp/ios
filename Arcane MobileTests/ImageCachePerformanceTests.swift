import Synchronization
import Testing
import UIKit

@testable import Arcane_Mobile

@MainActor
@Suite("Image cache performance")
struct ImageCachePerformanceTests {
    @Test
    func decodeDownsamplesToRequestedPixelSize() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 100))
        let data = try #require(renderer.image { context in
            UIColor.red.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        }.pngData())

        let image = try #require(ImageCache.decode(data: data, maxPixelSize: 40))

        #expect(image.cgImage?.width == 40)
        #expect(image.cgImage?.height == 20)
    }

    @Test
    func concurrentLoadsShareOneFetch() async throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24))
        let data = try #require(renderer.image { context in
            UIColor.blue.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }.pngData())
        let fetchCount = Mutex(0)
        let key = "https://performance.invalid/\(UUID().uuidString).png"

        await withTaskGroup(of: UIImage?.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await ImageCache.shared.load(key, maxPixelSize: 24) { _ in
                        fetchCount.withLock { $0 += 1 }
                        try? await Task.sleep(for: .milliseconds(20))
                        return data
                    }
                }
            }

            for await image in group {
                #expect(image != nil)
            }
        }

        #expect(fetchCount.withLock { $0 } == 1)
    }
}
