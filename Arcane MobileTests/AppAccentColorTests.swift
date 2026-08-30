import SwiftUI
import Testing
import UIKit

@testable import Arcane_Mobile

@Suite("App accent color")
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

}
