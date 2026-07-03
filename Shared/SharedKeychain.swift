import Foundation
import Arcane

/// Keychain constants shared by the app and the widget/intents extension.
/// The access group lets both processes read the same session tokens; it
/// requires the Keychain Sharing entitlement
/// (`$(AppIdentifierPrefix)com.getarcaneapp.ios.mobile.shared`) on both targets.
nonisolated enum SharedKeychain {
    static let service = "com.arcane.mobile.tokens"
    /// Team ID prefix is fixed for this app's signing identity.
    static let accessGroup = "4L6GXKX423.com.getarcaneapp.ios.mobile.shared"

    /// The shared-group store — what intents/widgets read, and what the app
    /// migrates into.
    static var sharedStore: KeychainTokenStore {
        KeychainTokenStore(service: service, accessGroup: accessGroup)
    }

    /// The app's original private-keychain item (pre-App-Group builds).
    static var legacyStore: KeychainTokenStore {
        KeychainTokenStore(service: service)
    }

    /// The legacy item addressed by its explicit access group (the app-ID
    /// group items landed in before the keychain-access-groups entitlement
    /// existed). An unqualified query *should* search this group too, but on
    /// some systems the entitlement change makes it miss — querying the group
    /// explicitly is the reliable upgrade path.
    static var legacyAppGroupStore: KeychainTokenStore {
        KeychainTokenStore(service: service, accessGroup: "4L6GXKX423.com.getarcaneapp.ios.mobile")
    }
}
