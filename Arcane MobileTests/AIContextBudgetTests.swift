import Foundation
import FoundationModels
import Arcane
import XCTest

@testable import Arcane_Mobile

final class AIAvailabilityTests: XCTestCase {
    func testAssistantExposureFailsClosed() {
        XCTAssertTrue(AIAvailability.available.allowsExposure)
        XCTAssertTrue(AIAvailability.aiNotEnabled.allowsExposure)
        XCTAssertTrue(AIAvailability.modelNotReady.allowsExposure)

        XCTAssertFalse(AIAvailability.checking.allowsExposure)
        XCTAssertFalse(AIAvailability.osTooOld.allowsExposure)
        XCTAssertFalse(AIAvailability.deviceNotEligible.allowsExposure)
        XCTAssertFalse(AIAvailability.configurationTooLarge.allowsExposure)
        XCTAssertFalse(AIAvailability.unknown.allowsExposure)
    }
}

@available(iOS 26, *)
final class AIContextBudgetTests: XCTestCase {
    func testConfigurationAndTurnBoundaries() {
        XCTAssertTrue(AIContextBudget.configurationFits(baseTokens: 3_008))
        XCTAssertFalse(AIContextBudget.configurationFits(baseTokens: 3_009))

        XCTAssertTrue(AIContextBudget.turnFits(baseTokens: 3_000, promptTokens: 200))
        XCTAssertFalse(AIContextBudget.turnFits(baseTokens: 3_000, promptTokens: 201))
    }

    func testFallbackCountUsesUTF8BytesAndFraming() {
        let text = "é🙂"
        XCTAssertEqual(AIContextBudget.fallbackTextTokens(text), text.utf8.count + 8)
        XCTAssertEqual(AIContextBudget.fallbackTextTokens(""), 0)
    }

    func testUnicodeTruncationPreservesHeadTailAndByteLimit() {
        let text = "BEGIN-" + String(repeating: "🙂é", count: 80) + "-END"
        let limited = AITextLimiter.headAndTail(text, maximumUTF8Bytes: 96)

        XCTAssertLessThanOrEqual(limited.utf8.count, 96)
        XCTAssertTrue(limited.hasPrefix("BEGIN"))
        XCTAssertTrue(limited.hasSuffix("END"))
        XCTAssertTrue(limited.contains("output truncated"))
    }

    func testSystemNotesAreBounded() {
        let note = String(repeating: "failure detail ", count: 100)
        let bounded = AIContextBudget.boundedSystemNote(note)
        XCTAssertLessThanOrEqual(bounded.utf8.count, 160)
        XCTAssertTrue(bounded.contains("output truncated"))
    }

    func testAggregateToolBudgetCanBeExhaustedSafely() async {
        let budget = AIContextBudget()
        await budget.beginToolOutputBudget(tokens: 8)

        let first = await budget.limitToolOutput(String(repeating: "a", count: 200))
        let second = await budget.limitToolOutput(String(repeating: "b", count: 200))

        XCTAssertEqual(first, "")
        XCTAssertEqual(second, "")
    }

    func testTranscriptGroupingKeepsOnlyCompleteTurns() {
        let instructions = Transcript.Entry.instructions(
            .init(segments: [.text(.init(content: "instructions"))], toolDefinitions: [])
        )
        let firstPrompt = Transcript.Entry.prompt(
            .init(segments: [.text(.init(content: "first"))])
        )
        let call = Transcript.ToolCall(
            id: "call-1",
            toolName: "testTool",
            arguments: GeneratedContent(properties: ["value": "one"])
        )
        let calls = Transcript.Entry.toolCalls(.init([call]))
        let output = Transcript.Entry.toolOutput(
            .init(
                id: "call-1",
                toolName: "testTool",
                segments: [.text(.init(content: "result"))]
            )
        )
        let firstResponse = Transcript.Entry.response(
            .init(assetIDs: [], segments: [.text(.init(content: "answer"))])
        )
        let secondPrompt = Transcript.Entry.prompt(
            .init(segments: [.text(.init(content: "second"))])
        )
        let secondResponse = Transcript.Entry.response(
            .init(assetIDs: [], segments: [.text(.init(content: "second answer"))])
        )
        let incompletePrompt = Transcript.Entry.prompt(
            .init(segments: [.text(.init(content: "incomplete"))])
        )

        let grouped = AITranscriptHistory.grouped([
            instructions,
            firstPrompt,
            calls,
            output,
            firstResponse,
            secondPrompt,
            secondResponse,
            incompletePrompt
        ])

        XCTAssertEqual(grouped.prefix, [instructions])
        XCTAssertEqual(grouped.turns.count, 2)
        XCTAssertEqual(grouped.turns[0], [firstPrompt, calls, output, firstResponse])
        XCTAssertEqual(grouped.turns[1], [secondPrompt, secondResponse])
    }

    func testHistoryRetentionKeepsNewestContiguousTurns() {
        XCTAssertEqual(
            AITranscriptHistory.retainedSuffixCount(
                turnCosts: [100, 80, 60],
                availableTokens: 150
            ),
            2
        )
        XCTAssertEqual(
            AITranscriptHistory.retainedSuffixCount(
                turnCosts: [40, 120, 60],
                availableTokens: 100
            ),
            1,
            "An older small turn must not be retained across a newer history gap"
        )
    }

    func testCapabilitySpecificRostersStayWithinLegacyLimit() {
        XCTAssertEqual(AIContextBudget.baseToolCount, 12)
        XCTAssertEqual(AIContextBudget.maximumToolCount, 13)
        XCTAssertLessThanOrEqual(
            AIContextBudget.maximumToolCount,
            AIContextBudget.legacyMaximumToolCount
        )
    }

    @MainActor
    @available(iOS 26.4, *)
    func testCapabilitySpecificRostersFitExactModelBudget() async throws {
        let model = SystemLanguageModel.default
        guard model.availability == .available else {
            throw XCTSkip("Exact tokenizer requires an available on-device model")
        }

        let client = ArcaneClient(
            configuration: .init(baseURL: try XCTUnwrap(URL(string: "https://arcane.invalid")))
        )
        let capabilities: [ServerCapabilities] = [
            .init(mode: .legacyRoles),
            .init(mode: .rbac)
        ]

        for capability in capabilities {
            let budget = AIContextBudget()
            let context = ArcaneToolContext(
                client: client,
                envID: .localDocker,
                envName: "Test",
                capabilities: capability,
                status: AIToolStatus()
            )
            let tools = AIToolbox.make(
                context: context,
                sink: AIPendingActionSink(),
                budget: budget
            )
            let text = AIInstructions.build(environmentName: "Test", capabilities: capability)
            async let instructionTokens = model.tokenCount(for: Instructions(text))
            async let toolTokens = model.tokenCount(for: tools)
            let baseTokens = try await instructionTokens + toolTokens

            XCTAssertTrue(
                AIContextBudget.configurationFits(baseTokens: baseTokens),
                "\(capability.mode.rawValue) roster uses \(baseTokens) base tokens"
            )
        }
    }
}
