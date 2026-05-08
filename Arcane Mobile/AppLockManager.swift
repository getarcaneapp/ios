import LocalAuthentication
import SwiftUI

@Observable
final class AppLockManager {
    var isLocked = false
    var isLockEnabled: Bool {
        didSet { UserDefaults.standard.set(isLockEnabled, forKey: "requireBiometricLock") }
    }

    private var isAuthenticating = false

    init() {
        isLockEnabled = UserDefaults.standard.bool(forKey: "requireBiometricLock")
    }

    var biometryType: LABiometryType {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return ctx.biometryType
    }

    var lockIcon: String {
        switch biometryType {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        default: return "lock.open.fill"
        }
    }

    var lockLabel: String {
        switch biometryType {
        case .faceID: return "Unlock with Face ID"
        case .touchID: return "Unlock with Touch ID"
        default: return "Unlock"
        }
    }

    func lockIfEnabled() {
        guard isLockEnabled else { return }
        isLocked = true
    }

    func authenticate() async {
        guard isLocked, !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }

        let ctx = LAContext()
        var error: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            isLocked = false
            return
        }

        let success = await withCheckedContinuation { continuation in
            ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Arcane Mobile") { success, _ in
                continuation.resume(returning: success)
            }
        }

        if success { isLocked = false }
    }
}
