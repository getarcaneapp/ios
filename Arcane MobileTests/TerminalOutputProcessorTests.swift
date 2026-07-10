import Foundation
import XCTest

@testable import Arcane_Mobile

final class TerminalOutputProcessorTests: XCTestCase {
    func testUTF8SurvivesEveryFrameSplit() {
        let bytes = Array("A€🙂Z".utf8)
        for split in 0...bytes.count {
            var decoder = TerminalFrameDecoder()
            let first = decoder.decode(Data(bytes[..<split]))
            let second = decoder.decode(Data(bytes[split...]))
            let final = decoder.finish()
            XCTAssertEqual(first.text + second.text + final.text, "A€🙂Z", "split \(split)")
        }
    }

    func testCSIAndDSRSurviveEveryFrameSplit() {
        let bytes = Array("left\u{001B}[31mred\u{001B}[0m\u{001B}[6nright".utf8)
        for split in 0...bytes.count {
            var decoder = TerminalFrameDecoder()
            let first = decoder.decode(Data(bytes[..<split]))
            let second = decoder.decode(Data(bytes[split...]))
            let final = decoder.finish()
            XCTAssertEqual(first.text + second.text + final.text, "leftredright", "split \(split)")
            XCTAssertEqual(first.dsrReplyCount + second.dsrReplyCount, 1, "split \(split)")
        }
    }

    func testOSCSurvivesEveryFrameSplit() {
        let bytes = Array("before\u{001B}]0;title\u{001B}\\after".utf8)
        for split in 0...bytes.count {
            var decoder = TerminalFrameDecoder()
            let first = decoder.decode(Data(bytes[..<split]))
            let second = decoder.decode(Data(bytes[split...]))
            XCTAssertEqual(first.text + second.text, "beforeafter", "split \(split)")
        }
    }

    func testOutputBufferBoundsLinesCharactersAndKeepsStableIDs() {
        var buffer = TerminalOutputBuffer(maxLines: 3, maxCharacters: 12)
        buffer.append("one\ntwo")
        let existingID = buffer.snapshot().lines.last?.id
        buffer.append("!")
        XCTAssertEqual(buffer.snapshot().lines.last?.id, existingID)

        buffer.append("\nthree\nfour\nfive")
        let snapshot = buffer.snapshot()

        XCTAssertLessThanOrEqual(snapshot.lines.count, 3)
        XCTAssertLessThanOrEqual(snapshot.fullText.count, 12)
        XCTAssertEqual(Set(snapshot.lines.map(\.id)).count, snapshot.lines.count)
    }
}
