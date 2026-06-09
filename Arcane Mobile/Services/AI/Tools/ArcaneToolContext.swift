import Arcane

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
}
