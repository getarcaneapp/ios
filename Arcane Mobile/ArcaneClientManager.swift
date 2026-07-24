import Foundation
import Arcane
import ArcaneOIDC
import AuthenticationServices
import CryptoKit
import Darwin

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
    private(set) var permissionsManifest: PermissionsManifest?
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
        mirrorToAppGroup()
        if previous != id {
            Task { await ResponseCache.shared.invalidateEnvironment(previous.rawValue) }
        }
    }

    // MARK: - Client
    private(set) var client: ArcaneClient?
    private(set) var clientGeneration = 0
    private var clientSession: URLSession?
    /// URL the current `client`/`clientSession` were built for; lets
    /// `configureClient` skip needless session rebuilds.
    private var configuredClientURL: URL?
    private var needsConnectionBootstrapRetry = false
    private var isRetryingConnectionBootstrap = false
    private var lastBootstrapDNSAddresses: [String] = []
    private static let bootstrapTimeout: TimeInterval = 20

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
        needsConnectionBootstrapRetry = false
        isRetryingConnectionBootstrap = false
        serverURL = normalized
        parsedServerURL = parsed
        currentUser = nil
        serverCapabilities = nil
        permissionsManifest = nil
        currentUserAvatarData = nil
        avatarFetchKey = nil
        lastBootstrapDNSAddresses = []
        Task { lastBootstrapDNSAddresses = await Self.resolveAddressesDetached(for: parsed) }
        // Explicit (re)configuration — always rebuild, even for the same URL.
        configureClient(for: parsed, force: true)
        authState = .login
        oidcInfo = nil
        mirrorToAppGroup()
        Task { await ResponseCache.shared.invalidateAll() }
        Task { await refreshOIDCStatus() }
    }

    func refreshOIDCStatus() async {
        guard client != nil else {
            oidcInfo = nil
            return
        }
        do {
            oidcInfo = try await withNetworkSessionRefreshRetry { client in
                try await self.fetchOIDCDisplayInfo(using: client)
            }
            needsConnectionBootstrapRetry = false
        } catch {
            needsConnectionBootstrapRetry = shouldRefreshNetworkSession(after: error)
            oidcInfo = nil
        }
    }

    func retryConnectionBootstrapIfNeeded() async {
        guard needsConnectionBootstrapRetry, !isRetryingConnectionBootstrap else { return }
        guard let client else {
            needsConnectionBootstrapRetry = false
            return
        }

        isRetryingConnectionBootstrap = true
        defer { isRetryingConnectionBootstrap = false }

        if (try? await client.authManager.hasRefreshCredential()) == true {
            await checkExistingAuth()
        } else {
            await refreshOIDCStatus()
        }
    }

    var isOIDCAvailable: Bool {
        oidcInfo?.enabled == true
    }

    var supportsActivities: Bool {
        serverCapabilities?.mode == .rbac
    }

    /// Whether the current session can reach a top-level app destination.
    /// v2 servers publish access-surface policy in the permissions manifest;
    /// v1 servers and older v2 servers without that metadata retain the app's
    /// existing admin/non-admin fallback.
    func canAccess(_ tab: AppTab) -> Bool {
        let supportsV2 = serverCapabilities?.mode == .rbac
        guard supportsV2 || !tab.requiresV2,
              let user = currentUser else {
            return false
        }

        if supportsV2,
           let permissionsManifest,
           !permissionsManifest.accessSurfaces.isEmpty,
           !tab.accessSurfaceIDs.isEmpty {
            return tab.accessSurfaceIDs.contains { surfaceID in
                permissionsManifest.canAccessSurface(
                    id: surfaceID,
                    user: user,
                    selectedEnvironmentID: activeEnvironmentID.rawValue
                )
            }
        }

        return user.isAdmin || !tab.requiresAdmin
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
            let response = try await withNetworkSessionRefreshRetry { client in
                try await client.auth.login(username: username, password: password)
            }
            await completeAuthenticatedBootstrap(
                user: response.user,
                capabilities: ServerCapabilities(mode: ServerCapabilities.detect(from: response.user)),
                client: self.client ?? client
            )
            needsConnectionBootstrapRetry = false
        } catch {
            needsConnectionBootstrapRetry = shouldRefreshNetworkSession(after: error)
            errorMessage = connectionAwareErrorMessage(error, passwordLogin: true)
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
            let capabilities = await client.serverCapabilities()
            await completeAuthenticatedBootstrap(user: result.user, capabilities: capabilities, client: client)
            needsConnectionBootstrapRetry = false
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
        guard let client else {
            signOutLocally()
            return
        }
        isLoading = true
        defer { isLoading = false }

        var logoutError: Error?
        do {
            try await client.auth.logout()
        } catch {
            logoutError = error
        }

        let credentialRemains: Bool
        do {
            credentialRemains = try await client.authManager.hasRefreshCredential()
        } catch {
            errorMessage = "Couldn't verify that local sign-in credentials were removed. \(friendlyErrorMessage(error))"
            return
        }

        guard !credentialRemains else {
            errorMessage = logoutError.map(friendlyErrorMessage)
                ?? "Couldn't remove local sign-in credentials."
            return
        }

        signOutLocally()
        errorMessage = nil
        DeploymentActivityStore.shared.sessionDidEnd()
        WidgetSnapshotPublisher.shared.publishSignedOut()
        await ResponseCache.shared.invalidateAll()
    }

    /// Mirror the widget-relevant defaults into the shared App Group so the
    /// widget extension and intents can read them (they can't see
    /// UserDefaults.standard). No-op until the App Groups capability exists.
    func mirrorToAppGroup() {
        guard let shared = AppGroup.defaults else { return }
        shared.set(serverURL, forKey: AppGroup.Keys.serverURL)
        shared.set(activeEnvironmentID.rawValue, forKey: AppGroup.Keys.activeEnvironmentID)
        shared.set(activeEnvironmentName, forKey: AppGroup.Keys.activeEnvironmentName)
        if let accent = UserDefaults.standard.string(forKey: "accentColorHex") {
            shared.set(accent, forKey: AppGroup.Keys.accentColorHex)
        }
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
                let capabilities = await client.serverCapabilities()
                await completeAuthenticatedBootstrap(user: response.user, capabilities: capabilities, client: client)
                needsConnectionBootstrapRetry = false
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
        permissionsManifest = nil
        isDemoActive = false
        demoEndsAt = nil
        needsConnectionBootstrapRetry = false
        isRetryingConnectionBootstrap = false
        serverURL = ""
        client = nil
        clientGeneration &+= 1
        authState = .setup
        DeploymentActivityStore.shared.sessionDidEnd()
        WidgetSnapshotPublisher.shared.publishSignedOut()
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
            signOutLocally()
            await refreshOIDCStatus()
            return
        }

        do {
            let user = try await withNetworkSessionRefreshRetry { client in
                try await client.auth.me()
            }
            await completeAuthenticatedBootstrap(
                user: user,
                capabilities: ServerCapabilities(mode: ServerCapabilities.detect(from: user)),
                client: self.client ?? client
            )
            needsConnectionBootstrapRetry = false
        } catch let error as ArcaneError {
            switch error {
            case .unauthorized, .forbidden:
                // The server explicitly rejected the stored credential
                // (revoked/expired and not refreshable). This is the ONLY path
                // that signs the user out without an explicit logout.
                signOutLocally()
                await refreshOIDCStatus()
            default:
                // Transient bootstrap failures keep credentials intact but fall
                // back to login until a real user payload can be loaded.
                await keepSignedInIfCredentialPresent(client, after: error)
            }
        } catch {
            // Non-ArcaneError (URLError, cancellation, etc.) is also transient.
            await keepSignedInIfCredentialPresent(client, after: error)
        }
    }

    /// Preserve stored credentials after transient bootstrap failures without
    /// showing the signed-in UI until `auth/me` loads a real user.
    private func keepSignedInIfCredentialPresent(_ client: ArcaneClient, after error: Error) async {
        guard (try? await client.authManager.hasRefreshCredential()) == true else {
            signOutLocally()
            await refreshOIDCStatus()
            return
        }

        currentUser = nil
        serverCapabilities = nil
        permissionsManifest = nil
        authState = .login
        errorMessage = connectionAwareErrorMessage(error)
        needsConnectionBootstrapRetry = shouldRefreshNetworkSession(after: error)
    }

    private func signOutLocally() {
        authState = .login
        currentUser = nil
        currentUserAvatarData = nil
        avatarFetchKey = nil
        serverCapabilities = nil
        permissionsManifest = nil
        needsConnectionBootstrapRetry = false
    }

    /// Finishes every successful authentication path consistently. The
    /// manifest is session-scoped decision metadata, so a fetch failure must
    /// not prevent sign-in; navigation falls back to the legacy admin policy.
    private func completeAuthenticatedBootstrap(
        user: User,
        capabilities: ServerCapabilities,
        client: ArcaneClient
    ) async {
        currentUser = user
        serverCapabilities = capabilities
        if capabilities.mode == .rbac {
            permissionsManifest = try? await client.roles.availablePermissions()
        } else {
            permissionsManifest = nil
        }
        authState = .authenticated
    }

    // MARK: - Current user avatar

    /// Raw image bytes of the signed-in user's server-side profile picture,
    /// or `nil` when the user has no custom avatar (the server 404s).
    private(set) var currentUserAvatarData: Data?
    /// De-dupes fetches: user id + updatedAt, so profile edits re-sync it.
    private var avatarFetchKey: String?

    /// Sync the profile picture from the server. Safe to call from every
    /// view that renders the avatar — it only hits the network when the
    /// user (or their updatedAt) changed since the last fetch.
    ///
    /// Mirrors the web's avatar sources: a custom uploaded avatar wins;
    /// otherwise Gravatar by email when the server's `enableGravatar`
    /// setting is on (the only picture SSO users have unless they upload
    /// one, since the server doesn't import the OIDC picture claim).
    func refreshCurrentUserAvatar() async {
        guard let client, let user = currentUser else {
            currentUserAvatarData = nil
            avatarFetchKey = nil
            return
        }
        let key = "\(user.id)|\(user.updatedAt ?? "")"
        guard key != avatarFetchKey else { return }
        avatarFetchKey = key
        if let custom = try? await client.users.getAvatar(userId: user.id) {
            currentUserAvatarData = custom
            return
        }
        currentUserAvatarData = await fetchGravatar(for: user, using: client)
    }

    private func fetchGravatar(for user: User, using client: ArcaneClient) async -> Data? {
        guard let email = user.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !email.isEmpty else { return nil }
        // Only reach out to Gravatar when the server has it enabled, like
        // the web UI — don't leak email hashes to a third party otherwise.
        guard let settings = try? await client.settings.getSettings(),
              settings.first(where: { $0.key == "enableGravatar" })?.value.lowercased() == "true"
        else { return nil }
        let hash = SHA256.hash(data: Data(email.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        // d=404 keeps Gravatar's generated placeholders out — no image
        // means we show our own initials fallback.
        return await fetchImageData(urlString: "https://www.gravatar.com/avatar/\(hash)?s=160&d=404")
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
    private func configureClient(for url: URL, force: Bool = false) {
        // Reuse the live client when it already points at this URL: every
        // bootstrap round-trip (OIDC probe, login, session restore) used to
        // tear the session down and rebuild it, killing in-flight streams.
        if !force, client != nil, configuredClientURL == url { return }
        clientSession?.finishTasksAndInvalidate()
        let bundle = Self.makeClient(url: url)
        client = bundle.client
        clientGeneration &+= 1
        clientSession = bundle.session
        configuredClientURL = url
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

    private func withNetworkSessionRefreshRetry<T: Sendable>(
        _ operation: @escaping @Sendable (ArcaneClient) async throws -> T
    ) async throws -> T {
        guard let parsedServerURL else {
            throw ArcaneError.transport("No client")
        }

        lastBootstrapDNSAddresses = await Self.resolveAddressesDetached(for: parsedServerURL)
        do {
            let result = try await runBootstrapOperation(for: parsedServerURL, operation)
            configureClient(for: parsedServerURL)
            return result
        } catch {
            guard shouldRefreshNetworkSession(after: error) else {
                throw error
            }
            // The transient failure may be a wedged session — force a rebuild.
            configureClient(for: parsedServerURL, force: true)
            try? await Task.sleep(for: .milliseconds(500))
            let result = try await runBootstrapOperation(for: parsedServerURL, operation)
            configureClient(for: parsedServerURL)
            return result
        }
    }

    private func runBootstrapOperation<T: Sendable>(
        for url: URL,
        _ operation: @escaping @Sendable (ArcaneClient) async throws -> T
    ) async throws -> T {
        let bundle = Self.makeClient(url: url, bootstrap: true)
        defer { bundle.session.invalidateAndCancel() }
        return try await operation(bundle.client)
    }

    /// Blocking `getaddrinfo` — never call on the main actor; use
    /// `resolveAddressesDetached(for:)` instead.
    private nonisolated static func resolvedAddresses(for url: URL) -> [String] {
        guard let host = url.host(percentEncoded: false), !host.isEmpty else { return [] }
        return resolveAddresses(for: host)
    }

    /// Runs the blocking DNS resolve off the main actor so slow/unreachable
    /// DNS can't freeze the UI during server setup.
    private static func resolveAddressesDetached(for url: URL) async -> [String] {
        await Task.detached(priority: .userInitiated) {
            Self.resolvedAddresses(for: url)
        }.value
    }

    private nonisolated static func resolveAddresses(for host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM

        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        guard status == 0, let first = result else {
            return ["getaddrinfo failed \(status): \(String(cString: gai_strerror(status)))"]
        }
        defer { freeaddrinfo(first) }

        var addresses: [String] = []
        var pointer: UnsafeMutablePointer<addrinfo>? = first
        while let current = pointer {
            let info = current.pointee
            if let socketAddress = info.ai_addr {
                var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let nameStatus = getnameinfo(
                    socketAddress,
                    info.ai_addrlen,
                    &hostBuffer,
                    socklen_t(hostBuffer.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
                if nameStatus == 0 {
                    let endIndex = hostBuffer.firstIndex(of: 0) ?? hostBuffer.count
                    let bytes = hostBuffer[..<endIndex].map { UInt8(bitPattern: $0) }
                    addresses.append(String(decoding: bytes, as: UTF8.self))
                }
            }
            pointer = info.ai_next
        }

        return Array(Set(addresses)).sorted()
    }

    private func shouldRefreshNetworkSession(after error: Error) -> Bool {
        if let urlError = error as? URLError {
            return Self.isTransientNetworkError(urlError)
        }
        guard case ArcaneError.transport(let message) = error else { return false }
        let lower = message.lowercased()
        let transientPhrases = [
            "could not connect to the server",
            "connection refused",
            "network connection was lost",
            "timed out",
            "hostname could not be found",
            "server with the specified hostname could not be found",
            "cannot find host",
            "could not find host",
            "cannot connect to host",
            "no route to host",
            "network is unreachable",
            "network unreachable",
            "not connected to the internet",
            "internet connection appears to be offline",
            "offline",
            "dns"
        ]
        return transientPhrases.contains { lower.contains($0) }
    }

    private static func isTransientNetworkError(_ error: URLError) -> Bool {
        switch error.code {
        case .cannotFindHost,
             .cannotConnectToHost,
             .dnsLookupFailed,
             .networkConnectionLost,
             .notConnectedToInternet,
             .timedOut,
             .dataNotAllowed,
             .callIsActive:
            return true
        default:
            return false
        }
    }

    private func connectionAwareErrorMessage(_ error: Error, passwordLogin: Bool = false) -> String {
        if passwordLogin, case ArcaneError.unauthorized = error {
            return "Invalid username or password"
        }

        let base = friendlyErrorMessage(error)
        guard shouldSuggestPrivateRelayWorkaround(for: error) else {
            return base
        }
        return "\(base) If this is your local Arcane server, iCloud Private Relay or Limit IP Address Tracking may be bypassing local DNS. Turn it off for this Wi-Fi network, then try again."
    }

    private func shouldSuggestPrivateRelayWorkaround(for error: Error) -> Bool {
        guard shouldRefreshNetworkSession(after: error),
              let host = parsedServerURL?.host(percentEncoded: false),
              !Self.isIPAddress(host),
              !lastBootstrapDNSAddresses.isEmpty else {
            return false
        }
        return lastBootstrapDNSAddresses.allSatisfy(Self.isPublicIPAddress)
    }

    private static func isIPAddress(_ value: String) -> Bool {
        ipv4Octets(value) != nil || isIPv6Address(value)
    }

    private static func isPublicIPAddress(_ value: String) -> Bool {
        if let octets = ipv4Octets(value) {
            return !isPrivateIPv4(octets)
        }
        if isIPv6Address(value) {
            return !isPrivateIPv6(value)
        }
        return false
    }

    private static func ipv4Octets(_ value: String) -> [Int]? {
        let parts = value.split(separator: ".")
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return nil }
        return octets
    }

    private static func isPrivateIPv4(_ octets: [Int]) -> Bool {
        guard octets.count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (10, _), (127, _), (169, 254), (192, 168):
            return true
        case (172, 16...31), (100, 64...127):
            return true
        default:
            return false
        }
    }

    private static func isIPv6Address(_ value: String) -> Bool {
        var address = in6_addr()
        return value.withCString { inet_pton(AF_INET6, $0, &address) == 1 }
    }

    private static func isPrivateIPv6(_ value: String) -> Bool {
        var address = in6_addr()
        guard value.withCString({ inet_pton(AF_INET6, $0, &address) == 1 }) else { return false }
        let bytes = withUnsafeBytes(of: address) { Array($0) }
        guard let first = bytes.first else { return false }
        return value == "::1"
            || first == 0xfc
            || first == 0xfd
            || (first == 0xfe && (bytes.dropFirst().first ?? 0) & 0xc0 == 0x80)
    }

    private struct ClientBundle {
        let client: ArcaneClient
        let session: URLSession
    }

    private static func makeClient(url: URL, bootstrap: Bool = false) -> ClientBundle {
        let session = makeURLSession(bootstrap: bootstrap)
        let client = ArcaneClient(configuration: .init(
            baseURL: url,
            // Migrates the session into the shared keychain group so widget
            // buttons and Shortcuts intents can authenticate. Falls back to
            // (and keeps writing) the original private item — see
            // MigratingTokenStore for the sign-out-safety invariants.
            tokenStore: MigratingTokenStore(),
            defaultEnvironmentID: .localDocker,
            urlSession: session,
            retryPolicy: bootstrap
                ? .init(maxAttempts: 1, baseBackoff: .milliseconds(300), maxBackoff: .milliseconds(300))
                : .init(maxAttempts: 5, baseBackoff: .milliseconds(300), maxBackoff: .seconds(3))
        ))
        return ClientBundle(client: client, session: session)
    }

    private static func makeURLSession(bootstrap: Bool = false) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = !bootstrap
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = .shared
        configuration.httpShouldSetCookies = true
        configuration.timeoutIntervalForRequest = bootstrap ? bootstrapTimeout : 30
        // timeoutIntervalForResource caps a request's TOTAL lifetime — at the
        // old 60s it silently killed every long-lived NDJSON stream (dashboard,
        // activities) and large upload on this session. Stall protection comes
        // from timeoutIntervalForRequest (inter-data inactivity), which the
        // streams' 15s server heartbeats keep satisfied.
        configuration.timeoutIntervalForResource = bootstrap ? bootstrapTimeout : 60 * 60 * 24
        if #available(iOS 11.0, *) {
            configuration.multipathServiceType = .none
        }
        return URLSession(configuration: configuration)
    }

    private func loginErrorMessage(_ error: Error) -> String {
        connectionAwareErrorMessage(error, passwordLogin: true)
    }
}
