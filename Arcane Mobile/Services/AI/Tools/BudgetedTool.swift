import FoundationModels

/// Central output envelope for every Arcane tool. Forwarding the original
/// schema keeps model behavior unchanged while ensuring no return path can
/// bypass the active turn's context allowance.
@available(iOS 26, *)
nonisolated struct BudgetedTool<Base: Tool>: Tool where Base.Output == String, Base.Arguments: Sendable {
    typealias Arguments = Base.Arguments
    typealias Output = String

    let base: Base
    let budget: AIContextBudget

    var name: String { base.name }
    var description: String { base.description }
    var parameters: GenerationSchema { base.parameters }
    var includesSchemaInInstructions: Bool { base.includesSchemaInInstructions }

    func call(arguments: Base.Arguments) async throws -> String {
        let output = try await base.call(arguments: arguments)
        return await budget.limitToolOutput(output)
    }
}
