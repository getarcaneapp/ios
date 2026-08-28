import Foundation
import Testing

@testable import Arcane_Mobile

@Suite
struct TerminalOutputProcessorTests {
    @Test
    func utf8SurvivesEveryFrameSplit() {
        let bytes = Array("A€🙂Z".utf8)
        for split in 0...bytes.count {
            var decoder = TerminalFrameDecoder()
            let first = decoder.decode(Data(bytes[..<split]))
            let second = decoder.decode(Data(bytes[split...]))
            let final = decoder.finish()
            #expect(first.text + second.text + final.text == "A€🙂Z", "split \(split)")
        }
    }

    @Test
    func csiAndDSRSurviveEveryFrameSplit() {
        let bytes = Array("left\u{001B}[31mred\u{001B}[0m\u{001B}[6nright".utf8)
        for split in 0...bytes.count {
            var decoder = TerminalFrameDecoder()
            let first = decoder.decode(Data(bytes[..<split]))
            let second = decoder.decode(Data(bytes[split...]))
            let final = decoder.finish()
            #expect(first.text + second.text + final.text == "leftredright", "split \(split)")
            #expect(first.dsrReplyCount + second.dsrReplyCount == 1, "split \(split)")
        }
    }

    @Test
    func oscSurvivesEveryFrameSplit() {
        let bytes = Array("before\u{001B}]0;title\u{001B}\\after".utf8)
        for split in 0...bytes.count {
            var decoder = TerminalFrameDecoder()
            let first = decoder.decode(Data(bytes[..<split]))
            let second = decoder.decode(Data(bytes[split...]))
            #expect(first.text + second.text == "beforeafter", "split \(split)")
        }
    }

    @Test
    func decoderBoundsSingleFrameWork() {
        var decoder = TerminalFrameDecoder()
        let decoded = decoder.decode(Data(repeating: 0x78, count: 300_000))

        #expect(decoded.text.utf8.count == 256 * 1_024)
    }

    @Test
    func decoderDropsOversizedCSIState() {
        var decoder = TerminalFrameDecoder()
        let sequence = "\u{001B}[" + String(repeating: "1", count: 2_000) + "mOK"
        let decoded = decoder.decode(Data(sequence.utf8))

        #expect(decoded.text.hasSuffix("OK"))
        #expect(decoded.text.utf8.count < sequence.utf8.count)
    }

    @Test
    func outputBufferBoundsLinesCharactersAndKeepsStableIDs() {
        var buffer = TerminalOutputBuffer(maxLines: 3, maxCharacters: 12)
        buffer.append("one\ntwo")
        let existingID = buffer.snapshot().lines.last?.id
        buffer.append("!")
        #expect(buffer.snapshot().lines.last?.id == existingID)

        buffer.append("\nthree\nfour\nfive")
        let snapshot = buffer.snapshot()

        #expect(snapshot.lines.count <= 3)
        #expect(snapshot.fullText.count <= 12)
        #expect(Set(snapshot.lines.map(\.id)).count == snapshot.lines.count)
    }
}
