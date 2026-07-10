import Foundation

nonisolated struct TerminalDecodedChunk: Sendable, Equatable {
    let text: String
    let dsrReplyCount: Int
}

nonisolated struct TerminalFrameDecoder: Sendable {
    private enum EscapeState: Sendable {
        case text
        case escape
        case csi([UInt8])
        case osc(escapePending: Bool)
        case designator
    }

    private var escapeState: EscapeState = .text
    private var utf8Value: UInt32 = 0
    private var utf8Minimum: UInt32 = 0
    private var utf8ContinuationCount = 0

    mutating func decode(_ data: Data) -> TerminalDecodedChunk {
        var output = String()
        var dsrReplyCount = 0

        for byte in data {
            switch escapeState {
            case .text:
                consumeTextState(byte, output: &output)
            case .escape:
                consumeEscapeState(byte)
            case .csi(var parameters):
                consumeCSIState(byte, parameters: &parameters, dsrReplyCount: &dsrReplyCount)
            case .osc(let escapePending):
                consumeOSCState(byte, escapePending: escapePending)
            case .designator:
                escapeState = .text
            }
        }

        return TerminalDecodedChunk(text: output, dsrReplyCount: dsrReplyCount)
    }

    mutating func finish() -> TerminalDecodedChunk {
        var output = String()
        flushIncompleteUTF8(into: &output)
        escapeState = .text
        return TerminalDecodedChunk(text: output, dsrReplyCount: 0)
    }

    private mutating func consumeTextState(_ byte: UInt8, output: inout String) {
        if byte == 0x1B {
            flushIncompleteUTF8(into: &output)
            escapeState = .escape
        } else if byte != 0x07 {
            appendTextByte(byte, to: &output)
        }
    }

    private mutating func consumeEscapeState(_ byte: UInt8) {
        switch byte {
        case 0x5B:
            escapeState = .csi([])
        case 0x5D:
            escapeState = .osc(escapePending: false)
        case 0x28, 0x29, 0x2A, 0x2B, 0x25, 0x23:
            escapeState = .designator
        default:
            escapeState = .text
        }
    }

    private mutating func consumeCSIState(
        _ byte: UInt8,
        parameters: inout [UInt8],
        dsrReplyCount: inout Int
    ) {
        if (0x40...0x7E).contains(byte) {
            if byte == 0x6E, parameters == [0x36] {
                dsrReplyCount += 1
            }
            escapeState = .text
        } else {
            parameters.append(byte)
            escapeState = .csi(parameters)
        }
    }

    private mutating func consumeOSCState(_ byte: UInt8, escapePending: Bool) {
        if escapePending, byte == 0x5C {
            escapeState = .text
        } else if !escapePending, byte == 0x07 {
            escapeState = .text
        } else {
            escapeState = .osc(escapePending: byte == 0x1B)
        }
    }

    private mutating func appendTextByte(_ byte: UInt8, to output: inout String) {
        let current = byte
        while true {
            if utf8ContinuationCount == 0 {
                switch current {
                case 0x00...0x7F:
                    appendScalar(UInt32(current), to: &output)
                case 0xC2...0xDF:
                    utf8Value = UInt32(current & 0x1F)
                    utf8Minimum = 0x80
                    utf8ContinuationCount = 1
                case 0xE0...0xEF:
                    utf8Value = UInt32(current & 0x0F)
                    utf8Minimum = 0x800
                    utf8ContinuationCount = 2
                case 0xF0...0xF4:
                    utf8Value = UInt32(current & 0x07)
                    utf8Minimum = 0x10000
                    utf8ContinuationCount = 3
                default:
                    appendReplacement(to: &output)
                }
                return
            }

            guard (0x80...0xBF).contains(current) else {
                appendReplacement(to: &output)
                resetUTF8()
                continue
            }

            utf8Value = (utf8Value << 6) | UInt32(current & 0x3F)
            utf8ContinuationCount -= 1
            guard utf8ContinuationCount == 0 else { return }

            let scalar = utf8Value
            let valid = scalar >= utf8Minimum
                && scalar <= 0x10FFFF
                && !(0xD800...0xDFFF).contains(scalar)
            if valid {
                appendScalar(scalar, to: &output)
            } else {
                appendReplacement(to: &output)
            }
            resetUTF8()
            return
        }
    }

    private mutating func flushIncompleteUTF8(into output: inout String) {
        guard utf8ContinuationCount > 0 else { return }
        appendReplacement(to: &output)
        resetUTF8()
    }

    private mutating func resetUTF8() {
        utf8Value = 0
        utf8Minimum = 0
        utf8ContinuationCount = 0
    }

    private func appendScalar(_ value: UInt32, to output: inout String) {
        guard let scalar = UnicodeScalar(value) else {
            appendReplacement(to: &output)
            return
        }
        output.unicodeScalars.append(scalar)
    }

    private func appendReplacement(to output: inout String) {
        output.unicodeScalars.append(UnicodeScalar(0xFFFD)!)
    }
}

nonisolated struct TerminalOutputLine: Identifiable, Sendable, Equatable {
    let id: UInt64
    var text: String
}

nonisolated struct TerminalOutputSnapshot: Sendable, Equatable {
    let lines: [TerminalOutputLine]
    let fullText: String
}

nonisolated struct TerminalOutputBuffer: Sendable {
    private(set) var lines: [TerminalOutputLine] = []
    private var nextID: UInt64 = 0
    private var pendingCarriageReturn = false
    let maxLines: Int
    let maxCharacters: Int

    init(maxLines: Int = 2_000, maxCharacters: Int = 200_000) {
        self.maxLines = max(1, maxLines)
        self.maxCharacters = max(1, maxCharacters)
    }

    mutating func append(_ text: String) {
        for character in text {
            if pendingCarriageReturn {
                appendNewline()
                pendingCarriageReturn = false
                if character == "\n" { continue }
            }

            switch character {
            case "\r":
                pendingCarriageReturn = true
            case "\n":
                appendNewline()
            default:
                ensureCurrentLine()
                lines[lines.count - 1].text.append(character)
            }
        }
        trimToLimits()
    }

    mutating func clear() {
        lines.removeAll(keepingCapacity: true)
        nextID = 0
        pendingCarriageReturn = false
    }

    func snapshot() -> TerminalOutputSnapshot {
        TerminalOutputSnapshot(
            lines: lines,
            fullText: lines.map(\.text).joined(separator: "\n")
        )
    }

    private mutating func ensureCurrentLine() {
        guard lines.isEmpty else { return }
        lines.append(TerminalOutputLine(id: nextID, text: ""))
        nextID &+= 1
    }

    private mutating func appendNewline() {
        ensureCurrentLine()
        lines.append(TerminalOutputLine(id: nextID, text: ""))
        nextID &+= 1
    }

    private mutating func trimToLimits() {
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }

        var characterCount = retainedCharacterCount
        while lines.count > 1, characterCount > maxCharacters {
            lines.removeFirst()
            characterCount = retainedCharacterCount
        }
        if characterCount > maxCharacters, !lines.isEmpty {
            lines[0].text = String(lines[0].text.suffix(maxCharacters))
        }
    }

    private var retainedCharacterCount: Int {
        lines.reduce(max(0, lines.count - 1)) { $0 + $1.text.count }
    }
}

actor TerminalOutputProcessor {
    private var decoder = TerminalFrameDecoder()
    private var buffer = TerminalOutputBuffer()

    func append(_ data: Data) -> Int {
        let decoded = decoder.decode(data)
        buffer.append(decoded.text)
        return decoded.dsrReplyCount
    }

    func finish() {
        buffer.append(decoder.finish().text)
    }

    func clear() {
        decoder = TerminalFrameDecoder()
        buffer.clear()
    }

    func snapshot() -> TerminalOutputSnapshot {
        buffer.snapshot()
    }
}
