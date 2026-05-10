import Foundation
import Arcane

enum AppAuthState {
    case setup          // No server URL configured
    case authenticating // Server URL set, checking existing tokens
    case login          // Server URL configured, not authenticated
    case authenticated  // Logged in
}

@Observable
final class ArcaneClientManager {
    // MARK: - Persisted config
    var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: "arcane.serverURL") }
    }

    // MARK: - Auth state
    var authState: AppAuthState = .setup
    var currentUser: ArcaneUser?
    var isLoading: Bool = false
    var errorMessage: String?

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
        client = Self.makeClient(url: parsed)
        authState = .login
        Task { await ResponseCache.shared.invalidateAll() }
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
            currentUser = ArcaneUser(
                id: response.user.id,
                username: response.user.username,
                email: response.user.email,
                roles: response.user.roles,
                canDelete: true,
                requiresPasswordChange: response.user.requiresPasswordChange
            )
            authState = .authenticated
        } catch let error as ArcaneError {
            errorMessage = arcaneErrorMessage(error)
        } catch {
            errorMessage = friendlyErrorMessage(error)
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
                currentUser = ArcaneUser(
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
            } catch let error as ArcaneError {
                errorMessage = arcaneErrorMessage(error)
                await DemoService.shared.endSession()
            } catch {
                errorMessage = friendlyErrorMessage(error)
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

        await DemoService.shared.endSession()

        try? await client?.auth.logout()
        currentUser = nil
        isDemoActive = false
        demoEndsAt = nil
        serverURL = ""
        client = nil
        authState = .setup
        await ResponseCache.shared.invalidateAll()

        if reason == .expired {
            demoExpiredMessage = "Your demo ended. Start a new one or connect to your own server."
        }
    }

    private func scheduleDemoExpiry(at date: Date) {
        demoExpiryTask?.cancel()
        let interval = date.timeIntervalSinceNow
        guard interval > 0 else {
            Task { await endDemo(reason: .expired) }
            return
        }
        demoExpiryTask = Task { [weak self] in
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
                return
            }
            let user = try await client.auth.me()
            currentUser = ArcaneUser(
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
        }
    }

    // MARK: - Image fetching

    func fetchImageData(urlString: String) async -> Data? {
        guard let client, let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        // Add auth headers for requests to our own server
        let serverBase = serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !serverBase.isEmpty && urlString.hasPrefix(serverBase),
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

    private func arcaneErrorMessage(_ error: ArcaneError) -> String {
        switch error {
        case .unauthorized: return "Invalid username or password"
        case .forbidden: return "You don't have permission to do that"
        case .notFound: return "Resource not found"
        case .conflict(let msg): return msg ?? "A conflict occurred"
        case .rateLimited: return "Too many requests — please wait"
        case .server(_, let msg): return msg
        case .transport(let msg): return "Connection error: \(msg)"
        case .decoding(let msg): return "Response error: \(msg)"
        case .unknown(let code, let body): return "Error \(code): \(body)"
        default: return "An error occurred"
        }
    }
}
