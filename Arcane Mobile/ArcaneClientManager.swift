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

    // MARK: - Init
    init() {
        let saved = UserDefaults.standard.string(forKey: "arcane.serverURL") ?? ""
        serverURL = saved
        if !saved.isEmpty, let url = URL(string: saved) {
            parsedServerURL = url
            let c = Self.makeClient(url: url)
            client = c
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
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: trimmed) else {
            errorMessage = "Invalid server URL"
            return
        }
        serverURL = trimmed
        parsedServerURL = parsed
        client = Self.makeClient(url: parsed)
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
            // The login page has no auth yet, so use the public settings
            // endpoint which exposes oidcEnabled + provider display fields.
            let data = try await client.transport.rawRequest(
                "environments/0/settings/public",
                body: Optional<String>.none,
                authorized: false
            )
            let settings = try JSONDecoder().decode([PublicSetting].self, from: data)
            let dict = Dictionary(settings.map { ($0.key, $0.value) }, uniquingKeysWith: { _, new in new })
            oidcInfo = OIDCDisplayInfo(
                enabled: dict["oidcEnabled"]?.lowercased() == "true",
                providerName: dict["oidcProviderName"] ?? "",
                providerLogoUrl: dict["oidcProviderLogoUrl"] ?? ""
            )
        } catch {
            oidcInfo = nil
        }
    }

    var isOIDCAvailable: Bool {
        oidcInfo?.enabled == true
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
            currentUser = User(
                id: response.user.id,
                username: response.user.username,
                email: response.user.email,
                roles: response.user.roles,
                canDelete: true,
                requiresPasswordChange: response.user.requiresPasswordChange
            )
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
            currentUser = User(
                id: result.user.id,
                username: result.user.username,
                email: result.user.email,
                roles: result.user.roles,
                canDelete: true,
                requiresPasswordChange: result.user.requiresPasswordChange
            )
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
                currentUser = User(
                    id: response.user.id,
                    username: response.user.username,
                    email: response.user.email,
                    roles: response.user.roles,
                    canDelete: false,
                    requiresPasswordChange: response.user.requiresPasswordChange
                )
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
        demoExpiryTask = Task { @concurrent [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            if Task.isCancelled { return }
            await self?.endDemo(reason: .expired)
        }
    }

    func checkExistingAuth() async {
        guard let client else {
            if authState == .authenticating { authState = .login }
            return
        }
        do {
            let hasCredential = try await client.authManager.hasRefreshCredential()
            guard hasCredential else {
                authState = .login
                await refreshOIDCStatus()
                return
            }
            let user = try await client.auth.me()
            currentUser = User(
                id: user.id,
                username: user.username,
                email: user.email,
                roles: user.roles,
                canDelete: true,
                requiresPasswordChange: user.requiresPasswordChange
            )
            authState = .authenticated
        } catch {
            authState = .login
            await refreshOIDCStatus()
        }
    }

    // MARK: - Image fetching

    func fetchImageData(urlString: String) async -> Data? {
        guard let client, let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        if let serverURL = parsedServerURL,
           ArcaneAPIHelpers.isSameOrigin(url, serverURL),
           let headers = try? await client.authManager.authenticationHeaders() {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    // MARK: - Private
    private static func makeClient(url: URL) -> ArcaneClient {
        ArcaneClient(configuration: .init(
            baseURL: url,
            tokenStore: KeychainTokenStore(service: "com.arcane.mobile.tokens"),
            defaultEnvironmentID: .localDocker
        ))
    }

    private func loginErrorMessage(_ error: Error) -> String {
        if case ArcaneError.unauthorized = error { return "Invalid username or password" }
        return friendlyErrorMessage(error)
    }
}
