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
    private let sink = AIPendingActionSink()
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
        if let prompt = seed.initialPrompt { inputDraft = prompt }
    }

    var contextBanner: String? { seed.contextBanner }
    var canSend: Bool {
        !inputDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isResponding
            && availability == .available
    }

    func refreshAvailability() {
        availability = AIAvailability.current()
    }

    func startSessionIfNeeded() {
        guard session == nil, availability == .available else { return }
        // `instructions:` is an @InstructionsBuilder closure, not a String arg.
        let s = LanguageModelSession(tools: AIToolbox.make(context: context, sink: sink)) {
            AIInstructions.build(environmentName: context.envName)
        }
        s.prewarm()
        session = s
    }

    // MARK: - Sending

    func send() { send(inputDraft) }

    func send(_ text: String) {
        let visible = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !visible.isEmpty, availability == .available, !isResponding, session != nil else { return }

        messages.append(.user(visible))
        inputDraft = ""
        // Prepend any pending action-result notes so the model stays truthful.
        let prompt = (pendingSystemNotes + [visible]).joined(separator: "\n")
        pendingSystemNotes.removeAll()

        let assistant = AIMessage.assistantPlaceholder()
        messages.append(assistant)
        isResponding = true

        streamTask = Task { [weak self] in
            await self?.runTurn(prompt: prompt, assistantID: assistant.id)
            await self?.finishTurn(assistantID: assistant.id)
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
        startSessionIfNeeded()
    }

    // MARK: - Streaming

    private func runTurn(prompt: String, assistantID: UUID) async {
        guard let session else { return }
        do {
            // streamResponse yields cumulative snapshots; `.content` is the whole
            // text so far — assign, never append.
            for try await partial in session.streamResponse(to: prompt) {
                update(assistantID, text: partial.content)
            }
        } catch let error as LanguageModelSession.GenerationError {
            await recover(from: error, prompt: prompt, assistantID: assistantID)
        } catch is CancellationError {
            // User stopped — keep whatever streamed.
        } catch {
            update(assistantID, text: "Sorry — \(friendlyErrorMessage(error))")
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
                update(assistantID, text: "This conversation got too long for me to continue. I've started a fresh session — please ask again.")
                return
            }
            didJustRebuild = true
            defer { didJustRebuild = false }
            rebuildSession()
            update(assistantID, text: "")
            await runTurn(prompt: prompt, assistantID: assistantID)   // retry once on the fresh session
        case .guardrailViolation:
            update(assistantID, text: "I can't help with that request.")
        default:
            update(assistantID, text: "Something went wrong generating that response. Please try again.")
        }
    }

    private func finishTurn(assistantID: UUID) async {
        if let idx = messages.firstIndex(where: { $0.id == assistantID }) {
            messages[idx].isStreaming = false
            if messages[idx].text.isEmpty {
                messages[idx].text = "Done."
            }
        }
        isResponding = false
        // Single reconciliation point: surface any actions staged this turn.
        let staged = await sink.drain()
        if !staged.isEmpty { visibleActions.append(contentsOf: staged) }
    }

    private func rebuildSession() {
        session = LanguageModelSession(tools: AIToolbox.make(context: context, sink: sink)) {
            AIInstructions.build(environmentName: context.envName)
        }
    }

    private func update(_ id: UUID, text: String) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].text = text
    }

    // MARK: - Confirming staged actions

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
        pendingSystemNotes.append("(System: the user declined to \(action.summary).)")
    }

    private func execute(_ action: AIPendingAction) {
        // Atomic claim — a second tap finds nothing and returns (no double-execute).
        guard visibleActions.contains(where: { $0.id == action.id }) else { return }
        visibleActions.removeAll { $0.id == action.id }

        actionTasks[action.id] = Task { [weak self] in
            guard let self else { return }
            defer { self.actionTasks[action.id] = nil }
            do {
                let summary = try await action.execute(client: self.context.client, envID: self.context.envID)
                self.invalidate(action)
                HapticsManager.success()
                showToast(.success(summary))
                self.messages.append(.system(summary))
                self.pendingSystemNotes.append("(System: the user approved and \(action.summary) succeeded — \(summary))")
            } catch {
                let message = friendlyErrorMessage(error)
                HapticsManager.warning()
                showToast(.error(message))
                self.messages.append(.system("Couldn't \(action.actionTitle.lowercased()) \(action.displayName): \(message)"))
                self.pendingSystemNotes.append("(System: \(action.summary) FAILED: \(message))")
            }
        }
    }
}
