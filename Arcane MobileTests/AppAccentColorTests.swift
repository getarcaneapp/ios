import Arcane
import SwiftUI
import Testing
import UIKit

@testable import Arcane_Mobile

@Suite("App accent color", .serialized)
struct AppAccentColorTests {
    @MainActor
    @Test
    func customAccentStylesTintAndExplicitAccentSurfaces() throws {
        let orange = try #require(Color(hex: "#FF9500"))
        let fixture = HStack(spacing: 0) {
            Rectangle().fill(Color.accentColor)
            Rectangle().fill(.tint)
        }
        .frame(width: 40, height: 20)
        .appAccentColor(orange)

        let renderer = ImageRenderer(content: fixture)
        renderer.scale = 1
        let image = try #require(renderer.uiImage)
        let pixels = try RGBAImage(image)

        for point in [CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 10)] {
            let pixel = pixels[point]
            #expect(pixel.red > 240)
            #expect(pixel.green > 120 && pixel.green < 180)
            #expect(pixel.blue < 30)
            #expect(pixel.alpha > 240)
        }
    }

    @MainActor
    @Test
    func toolbarSymbolUsesCustomAccent() throws {
        let orange = try #require(Color(hex: "#FF9500"))
        let fixture = Image(systemName: "circle.fill")
            .resizable()
            .frame(width: 20, height: 20)
            .appAccentToolbarSymbol()
            .appAccentColor(orange)

        let renderer = ImageRenderer(content: fixture)
        renderer.scale = 1
        let image = try #require(renderer.uiImage)
        let pixel = try RGBAImage(image)[CGPoint(x: 10, y: 10)]

        #expect(pixel.red > 240)
        #expect(pixel.green > 120 && pixel.green < 180)
        #expect(pixel.blue < 30)
        #expect(pixel.alpha > 240)
    }

    @MainActor
    @Test
    func destructiveLabelKeepsItsIconAndTitleRed() throws {
        let fixture = DestructiveLabel(text: "Clear")
            .font(.title2)
            .padding(8)
            .frame(width: 150, alignment: .leading)
            .background(.white)
            .foregroundStyle(.purple)
            .tint(.purple)

        let renderer = ImageRenderer(content: fixture)
        renderer.scale = 1
        let image = try #require(renderer.uiImage)
        let pixels = try RGBAImage(image)

        let iconRange = 8..<min(38, pixels.pixelWidth)
        let titleStart = min(44, pixels.pixelWidth - 1)
        let titleRange = titleStart..<pixels.pixelWidth

        #expect(pixels.redPixelCount(in: iconRange) > 5)
        #expect(pixels.redPixelCount(in: titleRange) > 5)
        #expect(pixels.purplePixelCount(in: iconRange) == 0)
    }

    @MainActor
    @Test
    func activityProgressBarRendersIntermediateFractions() async throws {
        let orange = try #require(Color(hex: "#FF9500"))
        let scene = try #require(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        for progress in [25, 75] {
            let fixture = ActivityProgressView(progress: progress, isActive: true, tint: orange)
                .frame(width: 200, height: 20)
                .background(.white)
            let host = UIHostingController(rootView: fixture)
            let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene)
            let bounds = CGRect(x: 0, y: 0, width: 390, height: 844)
            window.frame = bounds
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true; previousKeyWindow?.makeKey() }
            try await Task.sleep(for: .milliseconds(100))
            host.view.layoutIfNeeded()
            let bar = try #require(accentTestDescendants(of: UIProgressView.self, in: host.view).first)
            #expect(abs(bar.progress - Float(progress) / 100) < 0.001)
            let renderer = UIGraphicsImageRenderer(bounds: bounds, format: {
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                return format
            }())
            var rendered = false
            let screenshot = renderer.image { _ in
                rendered = window.drawHierarchy(in: bounds, afterScreenUpdates: true)
            }
            try #require(rendered)
            let image = UIImage(cgImage: try #require(screenshot.cgImage?.cropping(to: bar.convert(bar.bounds, to: window).integral)))
            let pixels = try RGBAImage(image)
            #expect(pixels.saturatedPixelCount(in: 0..<40) > 5)
            if progress == 25 {
                #expect(pixels.saturatedPixelCount(in: 120..<140) == 0)
            } else {
                #expect(pixels.saturatedPixelCount(in: 120..<140) > 5)
            }
            Attachment.record(image, named: "activity-progress-\(progress)", as: .png)
        }
    }

    @MainActor
    @Test
    func activityDetailNativeBackButtonUsesCustomAccent() async throws {
        let orange = try #require(Color(hex: "#FF9500"))
        let manager = ArcaneClientManager()
        let activity = Activity(id: "detail", environmentID: "one", type: .imagePull,
            status: .running, progress: 45, startedAt: .now, createdAt: .now)
        let fixture = NavigationStack(path: .constant(["detail"])) {
            Text("Activities")
                .navigationTitle("Activities")
                .navigationDestination(for: String.self) { _ in
                    ActivityDetailView(activity: activity)
                }
        }
        .environment(manager)
        .appAccentColor(orange)
        let scene = try #require(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.frame = bounds
        let host = UIHostingController(rootView: fixture)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previousKeyWindow?.makeKey() }
        try await Task.sleep(for: .milliseconds(400))
        host.view.layoutIfNeeded()
        let bar = try #require(accentTestDescendants(of: UINavigationBar.self, in: window)
            .last { !$0.isHidden && $0.alpha > 0 && $0.bounds.height > 0 })
        #expect(bar.topItem?.title == "Activity")
        let renderer = UIGraphicsImageRenderer(bounds: bounds, format: {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return format
        }())
        var rendered = false
        let screenshot = renderer.image { _ in
            rendered = window.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        try #require(rendered)
        let image = UIImage(cgImage: try #require(screenshot.cgImage?.cropping(to: bar.convert(bar.bounds, to: window).integral)))
        let pixels = try RGBAImage(image)
        #expect(pixels.orangePixelCount(in: 0..<min(100, pixels.pixelWidth)) > 5)
        Attachment.record(image, named: "activity-detail-back-accent", as: .png)
    }

    @MainActor
    @Test
    func navigationAndPresentedToolbarsUseAccentAndPreserveSemanticColors() async throws {
        let orange = try #require(Color(hex: "#FF9500"))
        for presentsSheet in [false, true] {
            let fixture = NavigationStack {
                AccentToolbarFixture()
            }
            .sheet(isPresented: .constant(presentsSheet)) {
                NavigationStack {
                    AccentToolbarFixture()
                }
            }
            .appAccentColor(orange)
            let bounds = CGRect(x: 0, y: 0, width: 390, height: 844)
            let host = UIHostingController(rootView: fixture)
            let scene = try #require(
                UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .first { $0.activationState == .foregroundActive }
            )
            let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene)
            window.frame = bounds
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                previousKeyWindow?.makeKey()
            }
            host.view.frame = bounds
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(400))
            host.view.layoutIfNeeded()

            let navigationBar = try #require(
                accentTestDescendants(of: UINavigationBar.self, in: window)
                    .last { !$0.isHidden && $0.alpha > 0 && $0.bounds.height > 0 }
            )
            let barFrame = navigationBar.convert(navigationBar.bounds, to: window).integral
            let renderer = UIGraphicsImageRenderer(bounds: bounds, format: {
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                return format
            }())
            var renderedHierarchy = false
            let screenshot = renderer.image { _ in
                renderedHierarchy = window.drawHierarchy(in: bounds, afterScreenUpdates: true)
            }
            try #require(renderedHierarchy)
            let image = UIImage(cgImage: try #require(screenshot.cgImage?.cropping(to: barFrame)))
            let pixels = try RGBAImage(image)
            let width = 0..<pixels.pixelWidth
            #expect(pixels.orangePixelCount(in: width) > 5)
            #expect(pixels.redPixelCount(in: width) > 5)
            #expect(pixels.greenPixelCount(in: width) > 5)
            Attachment.record(image, named: presentsSheet ? "sheet-navigation-accent" : "navigation-accent", as: .png)
        }
    }

}

private struct RGBAImage {
    struct Pixel {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        let alpha: UInt8
    }

    private let width: Int
    private let height: Int
    private let bytes: [UInt8]

    var pixelWidth: Int { width }

    init(_ image: UIImage) throws {
        let cgImage = try #require(image.cgImage)
        width = cgImage.width
        height = cgImage.height

        var storage = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue
        let context = try #require(CGContext(
            data: &storage,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        bytes = storage
    }

    subscript(point: CGPoint) -> Pixel {
        let x = min(max(Int(point.x), 0), width - 1)
        let y = min(max(Int(point.y), 0), height - 1)
        let offset = (y * width + x) * 4
        return Pixel(
            red: bytes[offset],
            green: bytes[offset + 1],
            blue: bytes[offset + 2],
            alpha: bytes[offset + 3]
        )
    }

    func redPixelCount(in xRange: Range<Int>) -> Int {
        pixelCount(in: xRange) { pixel in
            pixel.alpha > 80
                && pixel.red > 100
                && Int(pixel.red) > Int(pixel.green) + 40
                && Int(pixel.red) > Int(pixel.blue) + 40
        }
    }

    func orangePixelCount(in xRange: Range<Int>) -> Int {
        pixelCount(in: xRange) { pixel in
            pixel.alpha > 80 && pixel.red > 200
                && pixel.green > 80 && pixel.green < 190 && pixel.blue < 70
        }
    }

    func saturatedPixelCount(in xRange: Range<Int>) -> Int {
        pixelCount(in: xRange) { pixel in
            pixel.alpha > 80
                && Int(max(pixel.red, pixel.green, pixel.blue)) - Int(min(pixel.red, pixel.green, pixel.blue)) > 100
        }
    }

    func greenPixelCount(in xRange: Range<Int>) -> Int {
        pixelCount(in: xRange) { pixel in
            pixel.alpha > 80 && pixel.green > 100
                && Int(pixel.green) > Int(pixel.red) + 40
                && Int(pixel.green) > Int(pixel.blue) + 40
        }
    }

    func purplePixelCount(in xRange: Range<Int>) -> Int {
        pixelCount(in: xRange) { pixel in
            pixel.alpha > 80
                && pixel.red > 70
                && pixel.blue > 70
                && abs(Int(pixel.red) - Int(pixel.blue)) < 70
                && pixel.green < min(pixel.red, pixel.blue) / 2
        }
    }

    private func pixelCount(
        in xRange: Range<Int>,
        matching predicate: (Pixel) -> Bool
    ) -> Int {
        let lowerBound = max(xRange.lowerBound, 0)
        let upperBound = min(xRange.upperBound, width)
        guard lowerBound < upperBound else { return 0 }

        var count = 0
        for y in 0..<height {
            for x in lowerBound..<upperBound where predicate(self[CGPoint(x: x, y: y)]) {
                count += 1
            }
        }
        return count
    }

}

@MainActor
private struct AccentToolbarFixture: View {
    var body: some View {
        Color.white
            .navigationTitle("Accent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(id: "accent", placement: .topBarLeading) {
                    Button {} label: {
                        Image(systemName: "circle.fill")
                    }
                }
                AppToolbarItem(placement: .topBarTrailing) {
                    Button {} label: {
                        Image(systemName: "circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                AppToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {} label: {
                        DestructiveLabel(text: "Remove")
                    }
                }
            }
    }
}

@MainActor
private func accentTestDescendants<ViewType: UIView>(of type: ViewType.Type, in view: UIView) -> [ViewType] {
    view.subviews.flatMap { child in
        let matches = (child as? ViewType).map { [$0] } ?? []
        return matches + accentTestDescendants(of: type, in: child)
    }
}
