import Foundation
import Arcane

/// Errors surfaced to Shortcuts/Siri as readable sentences — never silent
/// failures.
nonisolated enum IntentClientError: Error, CustomLocalizedStringResourceConvertible {
    case notConfigured
    case demoMode

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notConfigured:
            return "Open Arcane and connect to a server first."
        case .demoMode:
            return "This action isn't available while Arcane is in demo mode."
        }
    }
}

/// Builds a short-timeout ArcaneClient for App Intents (widget refresh button,
/// Shortcuts actions) from the App-Group server URL and the shared keychain.
/// Refuses with readable errors when unconfigured or in demo mode. Note:
/// cookie-only auth behind a ForwardAuth proxy won't work here — the WebView
/// cookies live in the app process — so those setups fail with an auth error
/// from the server, which is surfaced as-is.
nonisolated enum IntentClientFactory {
    static func makeClient() throws -> ArcaneClient {
        if WidgetSnapshotStore.load()?.isDemo == true {
            throw IntentClientError.demoMode
        }
        guard let urlString = AppGroup.defaults?.string(forKey: AppGroup.Keys.serverURL),
              !urlString.isEmpty,
              let url = URL(string: urlString) else {
            throw IntentClientError.notConfigured
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 25
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil

        return ArcaneClient(configuration: .init(
            baseURL: url,
            tokenStore: SharedKeychain.sharedStore,
            defaultEnvironmentID: activeEnvironmentID,
            urlSession: URLSession(configuration: configuration),
            retryPolicy: .init(maxAttempts: 2, baseBackoff: .milliseconds(300), maxBackoff: .seconds(1))
        ))
    }

    static var activeEnvironmentID: EnvironmentID {
        let raw = AppGroup.defaults?.string(forKey: AppGroup.Keys.activeEnvironmentID)
        return raw.map { EnvironmentID(rawValue: $0) } ?? .localDocker
    }
}
