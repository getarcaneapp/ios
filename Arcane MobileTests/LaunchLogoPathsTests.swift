import CoreGraphics
import Testing

@testable import Arcane_Mobile

@Suite("Launch logo paths")
struct LaunchLogoPathsTests {
    @Test func bundledLogoParsesIntoOrderedPiecesInsideItsViewBox() throws {
        let logo = try #require(LaunchLogoPaths.bundled)
        #expect(logo.pieces.count == 13)
        #expect(logo.pieces.map(\.order) == Array(0..<13))
        let bounds = CGRect(origin: .zero, size: logo.size).insetBy(dx: -1, dy: -1)
        for piece in logo.pieces {
            #expect(!piece.path.isEmpty)
            #expect(bounds.contains(piece.path.boundingBoxOfPath))
        }
    }

    @Test func parsesRelativeCommandsWithImplicitRepeats() throws {
        let path = try #require(LaunchLogoPaths.parsePath("m 10,10 5,0 c 0,5 5,5 5,0 0,-5 5,-5 5,0 h 2 v 3 l 1,1 z"))
        let box = path.boundingBoxOfPath
        #expect(box.minX == 10)
        #expect(box.minY.rounded() == 6)
        #expect(box.maxX == 28)
        #expect(path.currentPoint == CGPoint(x: 10, y: 10))
    }

    @Test func parsesPolygons() throws {
        let path = try #require(LaunchLogoPaths.parsePolygon("0 0 10,0 10 5"))
        #expect(path.boundingBoxOfPath == CGRect(x: 0, y: 0, width: 10, height: 5))
        #expect(LaunchLogoPaths.parsePolygon("0 0 10") == nil)
    }

    @Test func unsupportedCommandsFailInsteadOfDrawingGarbage() {
        #expect(LaunchLogoPaths.parsePath("m 0,0 a 5,5 0 0 1 10,0") == nil)
    }
}
