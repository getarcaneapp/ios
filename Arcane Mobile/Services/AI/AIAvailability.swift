import Foundation
import FoundationModels   // iOS 26+; weak-linked. Symbol use is @available-gated.

/// App-facing availability of the on-device model, decoupled from the
/// `FoundationModels` types so unrestricted code (AppTab, contextual buttons)
/// can reason about it without an `#available` block at every call site.
enum AIAvailability: Equatable, Sendable {
    case checking
    case available
    case osTooOld            // running below iOS 26
    case deviceNotEligible   // hardware can't run Apple Intelligence
    case aiNotEnabled        // user hasn't turned Apple Intelligence on
    case modelNotReady       // assets still downloading
    case unknown

    /// Maps `SystemLanguageModel.default.availability` into our enum.
    @available(iOS 26, *)
    static func current() -> AIAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(.deviceNotEligible):
            return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled):
            return .aiNotEnabled
        case .unavailable(.modelNotReady):
            return .modelNotReady
        case .unavailable:
            return .unknown
        @unknown default:
            return .unknown
        }
    }

    /// Convenience for unrestricted code: `true` only on iOS 26+ when the model
    /// is ready right now. Lets non-gated views guard an "Ask AI" affordance
    /// without their own `#available` branch.
    static var isReady: Bool {
        if #available(iOS 26, *) { return current() == .available }
        return false
    }
}
