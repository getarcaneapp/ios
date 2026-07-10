import Foundation
import FoundationModels

/// Owns the model's fixed context allocations and the shared tool-output
/// allowance for the active turn. Tool calls can run concurrently, so the
/// mutable allowance belongs to an actor rather than the MainActor service.
@available(iOS 26, *)
actor AIContextBudget {
    nonisolated static let responseTokens = 384
    nonisolated static let toolOutputTokens = 384
    nonisolated static let perToolOutputTokens = 192
    nonisolated static let safetyTokens = 128
    nonisolated static let minimumPromptTokens = 192

    /// iOS 26.0–26.3 cannot tokenize schemas. This ceiling is validated by the
    /// exact iOS 26.4+ preflight and paired with a hard roster-size guard.
    nonisolated static let legacyBaseTokenCeiling = 3_000
    nonisolated static let legacyInstructionByteLimit = 2_048
    nonisolated static let baseToolCount = 12
    nonisolated static let maximumToolCount = 13
    nonisolated static let legacyMaximumToolCount = 13

    enum PreparationError: Error, Equatable {
        case configurationTooLarge
        case promptTooLarge
    }

    struct PreparedTurn: Sendable {
        let transcript: Transcript
        let retainedTurnCount: Int
    }

    private let model = SystemLanguageModel.default
    private var baseTokens: Int?
    private var remainingToolOutputTokens = 0

    func preflight(
        instructions: Instructions,
        instructionText: String,
        tools: [any Tool]
    ) async throws {
        let measured: Int?
        if #available(iOS 26.4, *) {
            do {
                async let instructionTokens = model.tokenCount(for: instructions)
                async let toolTokens = model.tokenCount(for: tools)
                measured = try await instructionTokens + toolTokens
            } catch {
                measured = nil
            }
        } else {
            measured = nil
        }

        let base: Int
        if let measured {
            base = measured
        } else {
            guard tools.count <= Self.legacyMaximumToolCount,
                  instructionText.utf8.count <= Self.legacyInstructionByteLimit else {
                throw PreparationError.configurationTooLarge
            }
            // Dynamic text uses the UTF-8 upper bound below. The static schema
            // portion uses a checked ceiling because schema tokenization is not
            // public before iOS 26.4.
            base = Self.legacyBaseTokenCeiling
        }

        guard Self.configurationFits(baseTokens: base, contextSize: model.contextSize) else {
            throw PreparationError.configurationTooLarge
        }
        baseTokens = base
    }

    func prepareTurn(transcript: Transcript, prompt: String) async throws -> PreparedTurn {
        guard let baseTokens else { throw PreparationError.configurationTooLarge }

        let promptTokens = await countText(prompt)
        let fixedTokens = baseTokens
            + promptTokens
            + Self.responseTokens
            + Self.toolOutputTokens
            + Self.safetyTokens
        guard fixedTokens <= model.contextSize else {
            throw PreparationError.promptTooLarge
        }

        let grouped = AITranscriptHistory.grouped(Array(transcript))
        var turnCosts: [Int] = []
        for turn in grouped.turns {
            turnCosts.append(await countTranscript(turn))
        }
        let retainedCount = AITranscriptHistory.retainedSuffixCount(
            turnCosts: turnCosts,
            availableTokens: model.contextSize - fixedTokens
        )
        let retained = Array(grouped.turns.suffix(retainedCount))

        beginToolOutputBudget()
        let entries = grouped.prefix + retained.flatMap { $0 }
        return PreparedTurn(
            transcript: Transcript(entries: entries),
            retainedTurnCount: retainedCount
        )
    }

    /// Applies both a per-call and aggregate allowance. The allowance is
    /// reserved before tokenization awaits, preventing actor reentrancy from
    /// letting concurrent calls overspend the turn budget.
    func limitToolOutput(_ output: String) async -> String {
        let reserved = min(Self.perToolOutputTokens, remainingToolOutputTokens)
        guard reserved > 8 else { return "" }
        remainingToolOutputTokens -= reserved

        // Account for the transcript's tool-output framing as well as content.
        let contentAllowance = reserved - 8
        let limited = await truncate(output, to: contentAllowance)
        let used = min(contentAllowance, await countText(limited))
        remainingToolOutputTokens += contentAllowance - used
        return limited
    }

    nonisolated static func configurationFits(baseTokens: Int, contextSize: Int = 4_096) -> Bool {
        turnFits(
            baseTokens: baseTokens,
            promptTokens: minimumPromptTokens,
            contextSize: contextSize
        )
    }

    nonisolated static func turnFits(
        baseTokens: Int,
        promptTokens: Int,
        historyTokens: Int = 0,
        contextSize: Int = 4_096
    ) -> Bool {
        baseTokens
            + promptTokens
            + historyTokens
            + responseTokens
            + toolOutputTokens
            + safetyTokens <= contextSize
    }

    nonisolated static func fallbackTextTokens(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        // A tokenizer cannot emit more byte-backed tokens than the UTF-8 input
        // contains. Add framing overhead for its transcript segment.
        return text.utf8.count + 8
    }

    nonisolated static func boundedSystemNote(_ note: String) -> String {
        AITextLimiter.headAndTail(note, maximumUTF8Bytes: 160)
    }

    func beginToolOutputBudget(tokens: Int = toolOutputTokens) {
        remainingToolOutputTokens = max(0, tokens)
    }

    private func countText(_ text: String) async -> Int {
        if #available(iOS 26.4, *),
           let exact = try? await model.tokenCount(for: Prompt(text)) {
            return exact
        }
        return Self.fallbackTextTokens(text)
    }

    private func countTranscript(_ entries: [Transcript.Entry]) async -> Int {
        if #available(iOS 26.4, *),
           let exact = try? await model.tokenCount(for: entries) {
            return exact
        }
        return Self.fallbackTranscriptTokens(entries)
    }

    private func truncate(_ text: String, to maximumTokens: Int) async -> String {
        guard maximumTokens > 0 else { return "" }
        guard await countText(text) > maximumTokens else { return text }

        if #available(iOS 26.4, *) {
            let scalarCount = text.unicodeScalars.count
            var lower = 0
            var upper = scalarCount
            var best = ""
            while lower <= upper {
                let midpoint = (lower + upper) / 2
                let candidate = AITextLimiter.headAndTail(text, keepingUnicodeScalars: midpoint)
                if await countText(candidate) <= maximumTokens {
                    best = candidate
                    lower = midpoint + 1
                } else {
                    upper = midpoint - 1
                }
            }
            return best
        }

        return AITextLimiter.headAndTail(text, maximumUTF8Bytes: max(0, maximumTokens - 8))
    }

    private nonisolated static func fallbackTranscriptTokens(_ entries: [Transcript.Entry]) -> Int {
        entries.reduce(0) { $0 + fallbackEntryTokens($1) }
    }

    private nonisolated static func fallbackEntryTokens(_ entry: Transcript.Entry) -> Int {
        switch entry {
        case let .prompt(prompt):
            return fallbackSegmentsTokens(prompt.segments) + 16
        case let .toolCalls(calls):
            return calls.reduce(16) { partial, call in
                partial + call.toolName.utf8.count + call.arguments.jsonString.utf8.count + 16
            }
        case let .toolOutput(output):
            return output.toolName.utf8.count + fallbackSegmentsTokens(output.segments) + 16
        case let .response(response):
            return fallbackSegmentsTokens(response.segments) + 16
        case .instructions:
            // Static instructions and schemas are represented by baseTokens.
            return 0
        case .reasoning:
            return 32
        @unknown default:
            return 32
        }
    }

    private nonisolated static func fallbackSegmentsTokens(_ segments: [Transcript.Segment]) -> Int {
        segments.reduce(0) { partial, segment in
            switch segment {
            case let .text(text):
                return partial + text.content.utf8.count + 8
            case let .structure(structured):
                return partial + structured.content.jsonString.utf8.count + 12
            case .attachment, .custom:
                return partial + 32
            @unknown default:
                return partial + 32
            }
        }
    }
}

@available(iOS 26, *)
nonisolated enum AITranscriptHistory {
    private enum EntryKind {
        case instructions
        case prompt
        case toolContext
        case response
        case other
    }

    /// Retains only the newest contiguous turns. If a newer turn does not fit,
    /// older turns are not used to create a misleading gap in conversation.
    static func retainedSuffixCount(turnCosts: [Int], availableTokens: Int) -> Int {
        var remaining = max(0, availableTokens)
        var retained = 0
        for cost in turnCosts.reversed() {
            guard cost <= remaining else { break }
            remaining -= cost
            retained += 1
        }
        return retained
    }

    static func grouped(
        _ entries: [Transcript.Entry]
    ) -> (prefix: [Transcript.Entry], turns: [[Transcript.Entry]]) {
        var prefix: [Transcript.Entry] = []
        var turns: [[Transcript.Entry]] = []
        var current: [Transcript.Entry] = []
        var sawPrompt = false

        for entry in entries {
            switch kind(of: entry) {
            case .instructions:
                if !sawPrompt { prefix.append(entry) }
            case .prompt:
                sawPrompt = true
                current = [entry]
            case .toolContext:
                if !current.isEmpty { current.append(entry) }
            case .response:
                if !current.isEmpty {
                    current.append(entry)
                    turns.append(current)
                    current = []
                }
            case .other:
                if !current.isEmpty { current.append(entry) }
            }
        }
        return (prefix, turns)
    }

    private static func kind(of entry: Transcript.Entry) -> EntryKind {
        switch entry {
        case .instructions: .instructions
        case .prompt: .prompt
        case .toolCalls, .toolOutput, .reasoning: .toolContext
        case .response: .response
        @unknown default: .other
        }
    }
}

/// Pure UTF-8/Unicode helpers kept separate so fallback behavior can be tested
/// without requiring an available on-device model.
nonisolated enum AITextLimiter {
    private static let marker = "\n… output truncated …\n"

    static func headAndTail(_ text: String, maximumUTF8Bytes: Int) -> String {
        guard text.utf8.count > maximumUTF8Bytes else { return text }
        guard maximumUTF8Bytes > 0 else { return "" }

        let markerBytes = marker.utf8.count
        guard maximumUTF8Bytes > markerBytes else {
            return prefix(text: marker, maximumUTF8Bytes: maximumUTF8Bytes)
        }

        let contentBytes = maximumUTF8Bytes - markerBytes
        let headBytes = contentBytes / 2
        let tailBytes = contentBytes - headBytes
        return prefix(text: text, maximumUTF8Bytes: headBytes)
            + marker
            + suffix(text: text, maximumUTF8Bytes: tailBytes)
    }

    static func headAndTail(_ text: String, keepingUnicodeScalars count: Int) -> String {
        let scalars = Array(text.unicodeScalars)
        guard count < scalars.count else { return text }
        guard count > 0 else { return "" }
        let headCount = count / 2
        let tailCount = count - headCount
        return string(from: scalars.prefix(headCount))
            + marker
            + string(from: scalars.suffix(tailCount))
    }

    private static func prefix(text: String, maximumUTF8Bytes: Int) -> String {
        var scalars: [Unicode.Scalar] = []
        var used = 0
        for scalar in text.unicodeScalars {
            let bytes = String(scalar).utf8.count
            guard used + bytes <= maximumUTF8Bytes else { break }
            scalars.append(scalar)
            used += bytes
        }
        return string(from: scalars)
    }

    private static func suffix(text: String, maximumUTF8Bytes: Int) -> String {
        var scalars: [Unicode.Scalar] = []
        var used = 0
        for scalar in text.unicodeScalars.reversed() {
            let bytes = String(scalar).utf8.count
            guard used + bytes <= maximumUTF8Bytes else { break }
            scalars.append(scalar)
            used += bytes
        }
        return string(from: scalars.reversed())
    }

    private static func string<S: Sequence>(from scalars: S) -> String where S.Element == Unicode.Scalar {
        String(String.UnicodeScalarView(scalars))
    }
}
