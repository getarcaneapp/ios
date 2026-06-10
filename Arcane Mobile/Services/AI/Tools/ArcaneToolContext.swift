import Arcane
import Observation

/// The `Sendable` capsule every AI tool captures instead of the
/// `@MainActor` `ArcaneClientManager`. Foundation Models invokes `Tool.call()`
/// off the main actor, so tools may only hold value/`Sendable` state — exactly
/// what `CachedClient` does (`struct CachedClient: Sendable { let client: ... }`).
///
/// The view extracts these copies off the manager on the MainActor at session
/// build time; nothing main-actor-isolated ever escapes into a tool.
struct ArcaneToolContext: Sendable {
    let client: ArcaneClient        // SDK client is Sendable (see CachedClient)
    let envID: EnvironmentID        // Sendable value type
    let envName: String
    /// Live "what is the assistant doing" relay — tools report a short line
    /// ("Checking containers…") that the thinking bubble shows in place of
    /// the generic "Thinking…".
    let status: AIToolStatus
}

/// MainActor-observable status line written from off-actor tool calls via the
/// nonisolated `report` hop. Implicitly @MainActor (project default isolation),
/// which also makes it Sendable for capture in `ArcaneToolContext`.
@Observable
final class AIToolStatus {
    var text: String?

    nonisolated func report(_ message: String) {
        Task { @MainActor in self.text = message }
    }
}
