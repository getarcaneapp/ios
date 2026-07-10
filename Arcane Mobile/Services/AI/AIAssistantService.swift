import Foundation
import Observation
import Arcane
import FoundationModels

/// Owns the on-device `LanguageModelSession`, the rendered transcript, and the
/// pending-action queue. Mirrors the app's `@MainActor @Observable` store shape
/// (see `ActivityCenterStore`). View-owned via `@State`, so its lifetime — and
/// the environment baked into its tools — tracks the screen.
///
/// Gated to iOS 26+ because it stores a `LanguageModelSession`.
@available(iOS 26, *)
@MainActor
@Observable
final class AIAssistantService {
    private(set) var messages: [AIMessage] = []
    private(set) var isResponding = false
    var availability: AIAvailability = .checking
    var inputDraft = ""

    /// Staged mutations awaiting confirmation; each renders an inline card.
    private(set) var visibleActions: [AIPendingAction] = []
    /// Set when a destructive action needs the app's red extra-friction card.
    var destructiveConfirm: AIPendingAction?

    private let context: ArcaneToolContext
    /// MainActor cache-invalidation hook supplied by the view (it has the manager).
    private let invalidate: @MainActor (AIPendingAction) -> Void
    private let sink: AIPendingActionSink
    private let budget: AIContextBudget
    private let instructionText: String
    private let instructions: Instructions
    private let tools: [any Tool]
    private let seed: AISeed

    @ObservationIgnored private var session: LanguageModelSession?
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    /// In-flight confirmed-action executions, keyed by action ID so each can be
    /// cancelled on conversation reset. Entries remove themselves on completion.
    @ObservationIgnored private var actionTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var didJustRebuild = false
    /// Result notes from confirmed actions, prepended to the next user prompt so
    /// the model learns outcomes without a wasted extra generation round-trip.
    @ObservationIgnored private var pendingSystemNotes: [String] = []

    init(
        context: ArcaneToolContext,
        seed: AISeed = .none,
        invalidate: @escaping @MainActor (AIPendingAction) -> Void
    ) {
        self.context = context
        self.seed = seed
        self.invalidate = invalidate
        let sink = AIPendingActionSink()
        let budget = AIContextBudget()
        let boundedEnvironmentName = ToolSupport.safeText(context.envName, maximumBytes: 80)
        let instructionText = AIInstructions.build(
            environmentName: boundedEnvironmentName,
            capabilities: context.capabilities
        )
        self.sink = sink
        self.budget = budget
        self.instructionText = instructionText
        self.instructions = Instructions(instructionText)
        self.tools = AIToolbox.make(context: context, sink: sink, budget: budget)
        if let prompt = seed.initialPrompt { inputDraft = prompt }
    }

    var contextBanner: String? { seed.contextBanner }
    /// Live "what is the assistant doing" line from tool calls, shown by the
    /// thinking bubble while a turn has no streamed text yet.
    var toolStatusText: String? { context.status.text }
    var canSend: Bool {
        !inputDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isResponding
            && availability == .available
    }

    func refreshAvailability() {
        availability = AIAvailability.current()
        if availability != .available { session = nil }
    }

    func startSessionIfNeeded() async {
        guard session == nil, availability == .available else { return }
        do {
            try await budget.preflight(
                instructions: instructions,
                instructionText: instructionText,
                tools: tools
            )
        } catch {
            availability = .configurationTooLarge
            return
        }
        let newSession = LanguageModelSession(tools: tools, instructions: instructions)
        newSession.prewarm()
        session = newSession
    }

    // MARK: - Sending

    func send() { send(inputDraft) }

    func send(_ text: String) {
        let visible = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !visible.isEmpty, availability == .available, !isResponding, session != nil else { return }

        messages.append(.user(visible))
        inputDraft = ""
        // Action outcomes are already bounded when queued. Keep only the newest
        // three so they cannot crowd the user's current request out of context.
        let notes = Array(pendingSystemNotes.suffix(3))
        pendingSystemNotes.removeAll()

        let assistant = AIMessage.assistantPlaceholder()
        messages.append(assistant)
        isResponding = true
        context.status.text = nil

        streamTask = Task { [weak self] in
            await self?.prepareAndRunTurn(
                userPrompt: visible,
                systemNotes: notes,
                assistantID: assistant.id
            )
        }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        isResponding = false
        if let last = messages.indices.last, messages[last].role == .assistant {
            messages[last].isStreaming = false
            if messages[last].text.isEmpty { messages[last].text = "(stopped)" }
        }
    }

    func clearConversation() {
        stop()
        actionTasks.values.forEach { $0.cancel() }
        actionTasks.removeAll()
        messages.removeAll()
        visibleActions.removeAll()
        pendingSystemNotes.removeAll()
        destructiveConfirm = nil
        session = nil
        Task { [weak self] in await self?.startSessionIfNeeded() }
    }

    // MARK: - Streaming

    private func prepareAndRunTurn(
        userPrompt: String,
        systemNotes: [String],
        assistantID: UUID
    ) async {
        guard let currentSession = session else {
            update(assistantID, text: Self.modelNotReadyText)
            await finishTurn(assistantID: assistantID)
            return
        }

        var prompt = (systemNotes + [userPrompt]).joined(separator: "\n")
        do {
            let prepared: AIContextBudget.PreparedTurn
            do {
                prepared = try await budget.prepareTurn(
                    transcript: currentSession.transcript,
                    prompt: prompt
                )
            } catch AIContextBudget.PreparationError.promptTooLarge where !systemNotes.isEmpty {
                // Never truncate user input. Action notes are useful context but
                // may be omitted when the current request only fits without them.
                prompt = userPrompt
                prepared = try await budget.prepareTurn(
                    transcript: currentSession.transcript,
                    prompt: prompt
                )
            }

            if prepared.transcript != currentSession.transcript {
                session = LanguageModelSession(tools: tools, transcript: prepared.transcript)
            }
            await runTurn(prompt: prompt, assistantID: assistantID)
        } catch AIContextBudget.PreparationError.promptTooLarge {
            pendingSystemNotes.insert(contentsOf: systemNotes, at: 0)
            update(
                assistantID,
                text: "That message is too long for the on-device model. Shorten it and try again."
            )
        } catch {
            update(
                assistantID,
                text: "Arcane Assistant's context budget is unavailable. Start a new conversation and try again."
            )
        }
        await finishTurn(assistantID: assistantID)
    }

    private func runTurn(prompt: String, assistantID: UUID) async {
        guard let session else { return }
        do {
            // streamResponse yields cumulative snapshots; `.content` is the whole
            // text so far — assign, never append.
            let options = GenerationOptions(maximumResponseTokens: AIContextBudget.responseTokens)
            for try await partial in session.streamResponse(to: prompt, options: options) {
                update(assistantID, text: partial.content)
            }
        } catch let error as LanguageModelSession.GenerationError {
            await recover(from: error, prompt: prompt, assistantID: assistantID)
        } catch is CancellationError {
            // User stopped — keep whatever streamed.
        } catch {
            // Availability can go stale mid-session (model assets purged or still
            // downloading throw "Local Model Asset unavailable" at generation
            // time). Re-check: if the model is no longer ready, flipping
            // `availability` swaps the chat for AIUnavailableView's guidance.
            refreshAvailability()
            if availability == .available {
                update(assistantID, text: "Sorry — \(friendlyErrorMessage(error))")
            } else {
                update(assistantID, text: Self.modelNotReadyText)
            }
        }
    }

    private func recover(
        from error: LanguageModelSession.GenerationError,
        prompt: String,
        assistantID: UUID
    ) async {
        switch error {
        case .exceededContextWindowSize:
            guard !didJustRebuild else {
                update(
                    assistantID,
                    text: "This conversation is too long to continue safely. Start a new conversation and ask again."
                )
                return
            }
            didJustRebuild = true
            defer { didJustRebuild = false }
            let fresh = LanguageModelSession(tools: tools, instructions: instructions)
            do {
                let prepared = try await budget.prepareTurn(
                    transcript: fresh.transcript,
                    prompt: prompt
                )
                session = LanguageModelSession(tools: tools, transcript: prepared.transcript)
                update(assistantID, text: "")
                await runTurn(prompt: prompt, assistantID: assistantID)
            } catch {
                update(
                    assistantID,
                    text: "That request is too large for the on-device model. Shorten it and try again."
                )
            }
        case .guardrailViolation:
            update(assistantID, text: "I can't help with that request.")
        case .assetsUnavailable:
            refreshAvailability()
            update(assistantID, text: Self.modelNotReadyText)
        default:
            update(assistantID, text: "Something went wrong generating that response. Please try again.")
        }
    }

    private static let modelNotReadyText = "Apple Intelligence's on-device model isn't ready; "
        + "it may still be downloading. Keep the device on Wi-Fi and power, then try again."

    private func finishTurn(assistantID: UUID) async {
        context.status.text = nil
        if let idx = messages.firstIndex(where: { $0.id == assistantID }) {
            messages[idx].isStreaming = false
            if messages[idx].text.isEmpty {
                messages[idx].text = "I couldn't produce a useful summary. "
                    + "Try asking about a specific container, project, or issue."
            }
        }
        isResponding = false
        streamTask = nil
        // Single reconciliation point: surface any actions staged this turn.
        let staged = await sink.drain()
        if !staged.isEmpty { visibleActions.append(contentsOf: staged) }
    }

    private func update(_ id: UUID, text: String) {
        // Once real text streams, the tool-status line is stale — drop it.
        if !text.isEmpty, context.status.text != nil { context.status.text = nil }
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].text = text
    }
}

// MARK: - Confirming staged actions

@available(iOS 26, *)
extension AIAssistantService {
    /// Called by an inline card's Confirm button. Destructive actions are routed
    /// to the app's red extra-friction card; others execute immediately.
    func requestConfirm(_ action: AIPendingAction) {
        if action.isDestructive {
            destructiveConfirm = action
        } else {
            execute(action)
        }
    }

    /// Called by the red confirmation card once the user approves a destructive action.
    func executeConfirmed(_ action: AIPendingAction) {
        execute(action)
    }

    func cancel(_ actionID: UUID) {
        guard let action = visibleActions.first(where: { $0.id == actionID }) else { return }
        visibleActions.removeAll { $0.id == actionID }
        appendSystemNote("(System: the user declined to \(action.summary).)")
    }

    private func execute(_ action: AIPendingAction) {
        // Atomic claim — a second tap finds nothing and returns (no double-execute).
        guard visibleActions.contains(where: { $0.id == action.id }) else { return }
        visibleActions.removeAll { $0.id == action.id }

        actionTasks[action.id] = Task { [weak self] in
            guard let self else { return }
            defer { self.actionTasks[action.id] = nil }
            do {
                let summary = try await action.execute(
                    client: self.context.client,
                    envID: self.context.envID
                )
                self.invalidate(action)
                HapticsManager.success()
                showToast(.success(summary))
                self.messages.append(.system(summary))
                self.appendSystemNote(
                    "(System: the user approved and \(action.summary) succeeded — \(summary))"
                )
            } catch {
                let message = friendlyErrorMessage(error)
                HapticsManager.warning()
                showToast(.error(message))
                let failure = "Couldn't \(action.actionTitle.lowercased()) \(action.displayName): \(message)"
                self.messages.append(.system(failure))
                self.appendSystemNote("(System: \(action.summary) FAILED: \(message))")
            }
        }
    }

    private func appendSystemNote(_ note: String) {
        pendingSystemNotes.append(AIContextBudget.boundedSystemNote(note))
        if pendingSystemNotes.count > 3 {
            pendingSystemNotes.removeFirst(pendingSystemNotes.count - 3)
        }
    }
}
