import Foundation
import Arcane
import ArcaneOIDC
import AuthenticationServices

enum AppAuthState {
    case setup          // No server URL configured
    case authenticating // Server URL set, checking existing tokens
    case login          // Server URL configured, not authenticated
    case authenticated  // Logged in
}

// URL scheme + path used for native OIDC callbacks. Must match the
// `OIDC_MOBILE_REDIRECT_URIS` allowlist on the backend and the OIDC
// provider's registered redirect URIs.
enum ArcaneMobileOIDC {
    static let callbackURLScheme = "arcane-mobile"
    static let redirectURI = "arcane-mobile://oidc-callback"
}

@Observable
final class ArcaneClientManager {
    // MARK: - Persisted config
    var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: "arcane.serverURL") }
    }
    private(set) var parsedServerURL: URL?

    // MARK: - Auth state
    var authState: AppAuthState = .setup
    var currentUser: User?
    var serverCapabilities: ServerCapabilities?
    var isLoading: Bool = false
    var errorMessage: String?

    // MARK: - OIDC
    struct OIDCDisplayInfo: Sendable {
        let enabled: Bool
        let providerName: String
        let providerLogoUrl: String
    }
    var oidcInfo: OIDCDisplayInfo?
    var isOIDCSigningIn: Bool = false

    // MARK: - Demo mode
    var isDemoActive: Bool = false
    var isStartingDemo: Bool = false
    var demoEndsAt: Date?
    var demoExpiredMessage: String?
    private var demoExpiryTask: Task<Void, Never>?

    // MARK: - Active environment
    var activeEnvironmentID: EnvironmentID = .localDocker
    var activeEnvironmentName: String = "Local Docker"

    func setActiveEnvironment(id: EnvironmentID, name: String) {
        let previous = activeEnvironmentID
        activeEnvironmentID = id
        activeEnvironmentName = name
        UserDefaults.standard.set(id.rawValue, forKey: "arcane.activeEnvironmentID")
        UserDefaults.standard.set(name, forKey: "arcane.activeEnvironmentName")
        if previous != id {
            Task { await ResponseCache.shared.invalidateEnvironment(previous.rawValue) }
        }
    }

    // MARK: - Client
    private(set) var client: ArcaneClient?
    private var clientSession: URLSession?

    // MARK: - Init
    init() {
        let saved = UserDefaults.standard.string(forKey: "arcane.serverURL") ?? ""
        serverURL = saved
        if !saved.isEmpty, let url = URL(string: saved) {
            parsedServerURL = url
            configureClient(for: url)
            authState = .authenticating
        }
        if let savedEnvID = UserDefaults.standard.string(forKey: "arcane.activeEnvironmentID") {
            activeEnvironmentID = EnvironmentID(rawValue: savedEnvID)
            activeEnvironmentName = UserDefaults.standard.string(forKey: "arcane.activeEnvironmentName") ?? "Local Docker"
        } else {
            // Persist the default env (id 0) so it's always explicit
            UserDefaults.standard.set(EnvironmentID.localDocker.rawValue, forKey: "arcane.activeEnvironmentID")
            UserDefaults.standard.set("Local Docker", forKey: "arcane.activeEnvironmentName")
        }
    }

    // MARK: - Server setup
    func configure(serverURL url: String) {
        // Clear any stale validation error before re-validating, so a previous
        // "Invalid server URL" doesn't linger once a good URL is entered.
        errorMessage = nil
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        // Default to https:// when the user omits a scheme. Local HTTP servers
        // must be entered with an explicit http:// prefix (see login help text).
        let normalized = (lowered.hasPrefix("http://") || lowered.hasPrefix("https://"))
            ? trimmed
            : "https://\(trimmed)"
        guard let parsed = URL(string: normalized), parsed.host != nil else {
            errorMessage = "Invalid server URL"
            return
        }
        serverURL = normalized
        parsedServerURL = parsed
        configureClient(for: parsed)
        authState = .login
        oidcInfo = nil
        Task { await ResponseCache.shared.invalidateAll() }
        Task { await refreshOIDCStatus() }
    }

    func refreshOIDCStatus() async {
        guard let client else {
            oidcInfo = nil
            return
        }
        do {
            oidcInfo = try await fetchOIDCDisplayInfo(using: client)
        } catch {
            if shouldRefreshNetworkSession(after: error), let parsedServerURL {
                configureClient(for: parsedServerURL)
                try? await Task.sleep(for: .milliseconds(500))
                if let refreshedClient = self.client,
                   let info = try? await fetchOIDCDisplayInfo(using: refreshedClient) {
                    oidcInfo = info
                    return
                }
            }
            oidcInfo = nil
        }
    }

    var isOIDCAvailable: Bool {
        oidcInfo?.enabled == true
    }

    var supportsActivities: Bool {
        serverCapabilities?.mode == .rbac
    }

    // MARK: - Auth
    func login(username: String, password: String) async {
        guard let client else {
            errorMessage = "No server configured"
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let response = try await client.auth.login(username: username, password: password)
            currentUser = response.user
            serverCapabilities = await client.serverCapabilities()
            authState = .authenticated
        } catch {
            errorMessage = loginErrorMessage(error)
        }
    }

    @MainActor
    func loginWithOIDC(anchor: ASPresentationAnchor) async {
        guard let client else {
            errorMessage = "No server configured"
            return
        }
        errorMessage = nil
        isOIDCSigningIn = true
        defer { isOIDCSigningIn = false }
        do {
            let authenticator = OIDCAuthenticator(client: client)
            let result = try await authenticator.signIn(
                callbackURLScheme: ArcaneMobileOIDC.callbackURLScheme,
                redirectURI: ArcaneMobileOIDC.redirectURI,
                presenting: anchor
            )
            currentUser = result.user
            serverCapabilities = await client.serverCapabilities()
            authState = .authenticated
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            // User cancelled the system sheet — no error message needed.
            return
        } catch {
            errorMessage = loginErrorMessage(error)
        }
    }

    func logout() async {
        if isDemoActive {
            await endDemo(reason: .userInitiated)
            return
        }
        guard let client else { return }
        isLoading = true
        defer { isLoading = false }
        try? await client.auth.logout()
        currentUser = nil
        serverCapabilities = nil
        authState = .login
        await ResponseCache.shared.invalidateAll()
    }

    // MARK: - Demo

    enum DemoEndReason {
        case userInitiated
        case expired
    }

    func startDemo() async {
        isLoading = true
        isStartingDemo = true
        errorMessage = nil
        demoExpiredMessage = nil
        defer {
            isLoading = false
            isStartingDemo = false
        }
        do {
            let session = try await DemoService.shared.startInstance()
            configure(serverURL: DemoService.demoBaseURL.absoluteString)

            guard let client else {
                errorMessage = "Failed to configure demo client"
                return
            }

            do {
                let response = try await client.auth.login(username: session.username, password: session.password)
                currentUser = response.user
                serverCapabilities = await client.serverCapabilities()
                authState = .authenticated
                isDemoActive = true
                demoEndsAt = session.endsAt
                DemoService.shared.startHeartbeat()
                scheduleDemoExpiry(at: session.endsAt)
            } catch {
                errorMessage = loginErrorMessage(error)
                await DemoService.shared.endSession()
            }
        } catch let error as DemoError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }

    func endDemo(reason: DemoEndReason) async {
        demoExpiryTask?.cancel()
        demoExpiryTask = nil

        // Update UI state synchronously first so the user is sent back to
        // the login screen immediately — don't make them wait on network
        // cleanup of the demo session and client logout.
        let endingClient = client
        currentUser = nil
        serverCapabilities = nil
        isDemoActive = false
        demoEndsAt = nil
        serverURL = ""
        client = nil
        authState = .setup
        if reason == .expired {
            demoExpiredMessage = "Your demo ended. Start a new one or connect to your own server."
        }

        await DemoService.shared.endSession()
        try? await endingClient?.auth.logout()
        await ResponseCache.shared.invalidateAll()
    }

    private func scheduleDemoExpiry(at date: Date) {
        demoExpiryTask?.cancel()
        let interval = date.timeIntervalSinceNow
        guard interval > 0 else {
            Task { await endDemo(reason: .expired) }
            return
        }
        demoExpiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(interval))
            if Task.isCancelled { return }
            await self?.endDemo(reason: .expired)
        }
    }

    func checkExistingAuth() async {
        guard let client else {
            if authState == .authenticating { authState = .login }
            return
        }

        // A keychain read hiccup (e.g. the device is momentarily locked right at
        // launch) is treated as "unknown" — never as signed-out. me() below
        // confirms the real state.
        let hasCredential: Bool
        do {
            hasCredential = try await client.authManager.hasRefreshCredential()
        } catch {
            hasCredential = true
        }

        guard hasCredential else {
            // No stored credential at all — the user is genuinely signed out.
            authState = .login
            await refreshOIDCStatus()
            return
        }

        do {
            currentUser = try await client.auth.me()
            serverCapabilities = await client.serverCapabilities()
            authState = .authenticated
        } catch let error as ArcaneError {
            switch error {
            case .unauthorized, .forbidden:
                // The server explicitly rejected the stored credential
                // (revoked/expired and not refreshable). This is the ONLY path
                // that signs the user out without an explicit logout.
                signOutLocally()
                await refreshOIDCStatus()
            default:
                // Transient failure (offline, timeout, server unreachable, 5xx).
                // Never bounce the user to login for these — keep them signed in
                // as long as the stored credential survives. user/capabilities
                // load on the next successful request.
                await keepSignedInIfCredentialPresent(client)
            }
        } catch {
            // Non-ArcaneError (URLError, cancellation, etc.) is also transient.
            await keepSignedInIfCredentialPresent(client)
        }
    }

    /// Stay authenticated after a transient failure as long as a refresh
    /// credential is still in the keychain. If a credential is genuinely gone we
    /// fall back to login (there's nothing left to retry with) rather than show a
    /// broken signed-in state.
    private func keepSignedInIfCredentialPresent(_ client: ArcaneClient) async {
        if (try? await client.authManager.hasRefreshCredential()) == true {
            authState = .authenticated
        } else {
            signOutLocally()
            await refreshOIDCStatus()
        }
    }

    private func signOutLocally() {
        authState = .login
        currentUser = nil
        serverCapabilities = nil
    }

    // MARK: - Image fetching

    func fetchImageData(urlString: String) async -> Data? {
        guard let client, let session = clientSession, let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        if let serverURL = parsedServerURL,
           ArcaneAPIHelpers.isSameOrigin(url, serverURL),
           let headers = try? await client.authManager.authenticationHeaders() {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    // MARK: - Private
    private func configureClient(for url: URL) {
        clientSession?.finishTasksAndInvalidate()
        let bundle = Self.makeClient(url: url)
        client = bundle.client
        clientSession = bundle.session
    }

    private func fetchOIDCDisplayInfo(using client: ArcaneClient) async throws -> OIDCDisplayInfo {
        // The login page has no auth yet, so use the public settings endpoint
        // which exposes oidcEnabled + provider display fields.
        let data = try await client.transport.rawRequest(
            "environments/0/settings/public",
            body: Optional<String>.none,
            authorized: false
        )
        let settings = try JSONDecoder().decode([PublicSetting].self, from: data)
        let dict = Dictionary(settings.map { ($0.key, $0.value) }, uniquingKeysWith: { _, new in new })
        return OIDCDisplayInfo(
            enabled: dict["oidcEnabled"]?.lowercased() == "true",
            providerName: dict["oidcProviderName"] ?? "",
            providerLogoUrl: dict["oidcProviderLogoUrl"] ?? ""
        )
    }

    private func shouldRefreshNetworkSession(after error: Error) -> Bool {
        guard case ArcaneError.transport(let message) = error else { return false }
        let lower = message.lowercased()
        return lower.contains("could not connect to the server")
            || lower.contains("connection refused")
            || lower.contains("network connection was lost")
            || lower.contains("timed out")
    }

    private struct ClientBundle {
        let client: ArcaneClient
        let session: URLSession
    }

    private static func makeClient(url: URL) -> ClientBundle {
        let session = makeURLSession()
        let client = ArcaneClient(configuration: .init(
            baseURL: url,
            tokenStore: KeychainTokenStore(service: "com.arcane.mobile.tokens"),
            defaultEnvironmentID: .localDocker,
            urlSession: session,
            retryPolicy: .init(maxAttempts: 5, baseBackoff: .milliseconds(300), maxBackoff: .seconds(3))
        ))
        return ClientBundle(client: client, session: session)
    }

    private static func makeURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = .shared
        configuration.httpShouldSetCookies = true
        configuration.timeoutIntervalForRequest = 30
        // timeoutIntervalForResource caps a request's TOTAL lifetime — at the
        // old 60s it silently killed every long-lived NDJSON stream (dashboard,
        // activities) and large upload on this session. Stall protection comes
        // from timeoutIntervalForRequest (inter-data inactivity), which the
        // streams' 15s server heartbeats keep satisfied.
        configuration.timeoutIntervalForResource = 60 * 60 * 24
        if #available(iOS 11.0, *) {
            configuration.multipathServiceType = .handover
        }
        return URLSession(configuration: configuration)
    }

    private func loginErrorMessage(_ error: Error) -> String {
        if case ArcaneError.unauthorized = error { return "Invalid username or password" }
        return friendlyErrorMessage(error)
    }
}
