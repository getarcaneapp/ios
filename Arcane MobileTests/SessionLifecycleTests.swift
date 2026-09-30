import Arcane
import Foundation
import Testing

@testable import Arcane_Mobile

private actor SessionGate {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async -> Bool {
        for _ in 0..<500 {
            if started { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    func release() { continuation?.resume(); continuation = nil }
}

private actor SuspendedCredentialStore: TokenStore {
    let gate: SessionGate
    private var tokens: TokenPair?
    init(gate: SessionGate) { self.gate = gate }
    func loadTokens() -> TokenPair? { tokens }
    func saveTokens(_ value: TokenPair) async {
        if value.accessToken == "old" { await gate.suspend() }
        tokens = value
    }
    func clearTokens() { tokens = nil }
}

private nonisolated final class BindingRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func record(_ value: String) { lock.withLock { values.append(value) } }
    var recorded: [String] { lock.withLock { values } }
}

private nonisolated final class SessionValidity: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    var current: Bool { lock.withLock { valid } }
    func retire() { lock.withLock { valid = false } }
}

@Suite("Credential lifecycle")
struct CredentialLifecycleTests {
    @Test func retiredWriteCannotBindOrReplaceTheNextAccount() async throws {
        let gate = SessionGate()
        let store = SuspendedCredentialStore(gate: gate)
        let persistence = CredentialPersistenceCoordinator()
        let oldLease = CredentialLease()
        let nextLease = CredentialLease()
        let bindings = BindingRecorder()
        let old = TokenPair(accessToken: "old", refreshToken: "old-refresh", expiresAt: .distantFuture)
        let next = TokenPair(accessToken: "next", refreshToken: "next-refresh", expiresAt: .distantFuture)
        let pending = Task { try await persistence.save(old, to: store, lease: oldLease) { bindings.record("old") } }
        #expect(await gate.waitUntilStarted())
        oldLease.retire()
        let replacement = Task { try await persistence.save(next, to: store, lease: nextLease) { bindings.record("next") } }
        await gate.release()
        do { try await pending.value; Issue.record("Retired authentication persisted") }
        catch is CancellationError {}
        try await replacement.value
        #expect(try await store.loadTokens() == next)
        #expect(bindings.recorded == ["next"])
    }

    @Test func retiredLogoutCannotClearReplacementCredentials() async throws {
        let persistence = CredentialPersistenceCoordinator()
        let store = InMemoryTokenStore(tokens: .init(accessToken: "next", refreshToken: "next", expiresAt: .distantFuture))
        let lease = CredentialLease()
        lease.retire()
        let bindings = BindingRecorder()
        do {
            try await persistence.clear(stores: [store], lease: lease) { bindings.record("unbound") }
            Issue.record("Retired logout cleared credentials")
        } catch is CancellationError {}
        #expect(try await store.loadTokens()?.accessToken == "next")
        #expect(bindings.recorded.isEmpty)
    }

    @Test func widgetClientCannotRotateOrClearTheReplacementSession() async throws {
        let validity = SessionValidity()
        let store = KeychainTokenStore(service: "retired-widget-test", validating: { validity.current })
        validity.retire()
        await #expect(throws: CancellationError.self) {
            try await store.saveTokens(.init(accessToken: "old", refreshToken: "old", expiresAt: .distantFuture))
        }
        await #expect(throws: CancellationError.self) { try await store.clearTokens() }
        await #expect(throws: CancellationError.self) { try await store.loadTokens() }
    }

    @Test(arguments: [1e30, -1e30, Double(Int64.max), Double.infinity, -Double.infinity, Double.nan])
    func dynamicNumbersRemainDisplayable(_ number: Double) {
        #expect(!AnyJSONValue.number(number).displayString.isEmpty)
    }

    @Test @MainActor func numericDisplayPreservesFractionsAndIntegerBoundaries() {
        #expect(AnyJSONValue.number(1.25).displayString == "1.25")
        #expect(AnyJSONValue.number(Double(Int64.min)).displayString == String(Int64.min))
        #expect(AnyJSONValue.number(42).displayString == "42")
        #expect(AnyJSONValue.number(1e30).displayString == "1e+30")
        let info = DockerInfo(success: true, apiVersion: "", gitCommit: "", goVersion: "", os: "", arch: "", buildTime: "", info: ["Containers": .number(1e30), "Images": .number(4.9)])
        #expect(info.containers == 0)
        #expect(info.images == 4)
    }
}

private nonisolated final class LifecycleURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) async throws -> Data
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    static func session(handler: @escaping Handler) -> URLSession {
        let key = UUID().uuidString
        lock.withLock { handlers[key] = handler }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LifecycleURLProtocol.self]
        configuration.httpAdditionalHeaders = ["Lifecycle-Test": key]
        return URLSession(configuration: configuration)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private var loadingTask: Task<Void, Never>?
    override func startLoading() {
        let handler = Self.lock.withLock { Self.handlers[request.value(forHTTPHeaderField: "Lifecycle-Test") ?? ""] }
        loadingTask = Task {
            do {
                guard let handler else { throw URLError(.badServerResponse) }
                let data = try await handler(request)
                guard !Task.isCancelled else { return }
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    override func stopLoading() { loadingTask?.cancel(); loadingTask = nil }
}

@Suite("Authentication session ownership", .serialized)
@MainActor
struct SessionLifecycleTests {
    @Test func failedRecoveryCodeRetainsTheMFAChallengeForRetry() async throws {
        let savedURL = UserDefaults.standard.string(forKey: "arcane.serverURL")
        defer { UserDefaults.standard.set(savedURL, forKey: "arcane.serverURL") }
        let manager = ArcaneClientManager(serverURL: "https://localhost", sessionFactory: { _ in
            LifecycleURLProtocol.session { _ in
                Data(#"{"success":false,"data":null,"error":"Invalid recovery code"}"#.utf8)
            }
        }, tokenStoreFactory: { _ in InMemoryTokenStore() })
        let challenge = MFAChallenge(transactionId: "transaction", expiresAt: .distantFuture)
        manager.pendingMFAChallenge = challenge
        manager.authState = .login
        await manager.completePendingMFAWithRecoveryCode("invalid")
        #expect(manager.pendingMFAChallenge == challenge)
        #expect(manager.errorMessage != nil)
        #expect(!manager.isLoading)
    }

    @Test func delayedPushStatusCannotRemoveTheNextServersBinding() async throws {
        let gate = SessionGate()
        let tokens = InMemoryTokenStore()
        let login = LoginResponse(token: "old", refreshToken: "old", expiresAt: .distantFuture, user: User(id: "old-user", username: "old-user"))
        let loginData = Data("{\"success\":true,\"data\":".utf8)
            + (try ArcaneJSON.makeEncoder().encode(login)) + Data("}".utf8)
        let versionData = try ArcaneJSON.makeEncoder().encode(VersionInfo(currentVersion: "v2.15.0", revision: "test", shortRevision: "test", goVersion: "test", enabledFeatures: ["mobile-push-v1"], displayVersion: "v2.15.0", isSemverVersion: true, updateAvailable: false))
        let savedURL = UserDefaults.standard.string(forKey: "arcane.serverURL")
        defer { UserDefaults.standard.set(savedURL, forKey: "arcane.serverURL") }
        let manager = ArcaneClientManager(serverURL: "https://localhost", sessionFactory: { _ in
            LifecycleURLProtocol.session { request in
                let path = request.url!.path
                if path.hasSuffix("auth/login") { return loginData }
                if path.hasSuffix("app-version") { return versionData }
                if path.hasSuffix("apns/status") {
                    await gate.suspend()
                    return Data(#"{"success":true,"data":{"enabled":false,"relayUrl":"https://relay.example","devices":[]}}"#.utf8)
                }
                return Data(#"{"success":true,"data":[]}"#.utf8)
            }
        }, tokenStoreFactory: { _ in tokens })
        await manager.login(username: "old-user", password: "password")
        try #require(manager.supportsMobilePush)
        let nextOrigin = "https://127.0.0.1:443"
        let coordinator = PushNotificationCoordinator(credentials: .init(relayURL: "https://relay.example", installationId: "installation", installationSecret: "test", deviceToken: "token", apnsEnvironment: "sandbox", bindings: [nextOrigin: .init(recipientId: "recipient", channelId: "channel", deviceId: "device")]), persistCredentials: { _ in })
        let pending = Task { await coordinator.refreshServerStatus(manager: manager) }
        defer { pending.cancel() }
        try #require(await gate.waitUntilStarted())
        manager.configure(serverURL: "https://127.0.0.1")
        await gate.release()
        await pending.value
        #expect(coordinator.serverStatus == nil)
        #expect(coordinator.binding(for: nextOrigin) != nil)
    }

    @Test func delayedPushTokenUpdateCannotRestoreRemovedBindings() async throws {
        let gate = SessionGate()
        let session = LifecycleURLProtocol.session { request in
            if request.url?.path.hasSuffix("token") == true { await gate.suspend() }
            return Data()
        }
        let origin = "https://localhost:443"
        let coordinator = PushNotificationCoordinator(
            credentials: .init(relayURL: "https://relay.example", installationId: "installation", installationSecret: "test", deviceToken: "old", apnsEnvironment: "sandbox", bindings: [origin: .init(recipientId: "recipient", channelId: "channel", deviceId: "device")]),
            relaySession: session, persistCredentials: { _ in }
        )
        coordinator.didRegister(deviceToken: Data([1, 2]))
        try #require(await gate.waitUntilStarted())
        await coordinator.tearDown(client: nil, origin: origin)
        await gate.release()
        for _ in 0..<100 {
            if coordinator.credentials?.deviceToken == "0102" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(coordinator.credentials?.deviceToken == "0102")
        #expect(coordinator.binding(for: origin) == nil)
    }

    @Test func delayedAvatarCannotReplaceTheNextServersAvatar() async throws {
        let gate = SessionGate()
        let tokens = InMemoryTokenStore(tokens: .init(accessToken: "old", refreshToken: "old", expiresAt: .distantFuture))
        let savedURL = UserDefaults.standard.string(forKey: "arcane.serverURL")
        defer { UserDefaults.standard.set(savedURL, forKey: "arcane.serverURL") }
        let manager = ArcaneClientManager(serverURL: "https://localhost", sessionFactory: { _ in
            LifecycleURLProtocol.session { request in
                if request.url?.path.hasSuffix("avatar") == true { await gate.suspend() }
                return Data("old avatar".utf8)
            }
        }, tokenStoreFactory: { _ in tokens })
        manager.currentUser = User(id: "old-user", username: "old-user")
        let pending = Task { await manager.refreshCurrentUserAvatar() }
        defer { pending.cancel() }
        try #require(await gate.waitUntilStarted())
        manager.configure(serverURL: "https://127.0.0.1")
        await gate.release()
        await pending.value
        #expect(manager.currentUserAvatarData == nil)
    }

    @Test func retiredFleetLoadCannotPopulateTheReplacementStore() async throws {
        let gate = SessionGate()
        let tokens = InMemoryTokenStore(tokens: .init(accessToken: "old", refreshToken: "old", expiresAt: .distantFuture))
        let savedURL = UserDefaults.standard.string(forKey: "arcane.serverURL")
        defer { UserDefaults.standard.set(savedURL, forKey: "arcane.serverURL") }
        let manager = ArcaneClientManager(serverURL: "https://localhost", sessionFactory: { _ in
            LifecycleURLProtocol.session { request in
                if request.url?.path.hasSuffix("environments") == true { await gate.suspend() }
                return Data(#"{"success":true,"data":[{"id":"old-env","name":"Old","apiUrl":"","status":"online"}],"pagination":{"totalItems":1,"totalPages":1,"currentPage":1,"itemsPerPage":50}}"#.utf8)
            }
        }, tokenStoreFactory: { _ in tokens })
        manager.currentUser = User(id: "old-user", username: "old-user")
        let fleet = FleetStore()
        let pending = Task { await fleet.load(manager: manager) }
        defer { pending.cancel() }
        try #require(await gate.waitUntilStarted())
        manager.configure(serverURL: "https://127.0.0.1")
        fleet.configure(client: manager.client)
        await gate.release()
        await pending.value
        #expect(fleet.environments.isEmpty)
        #expect(!fleet.hasLoaded)
        #expect(!fleet.isLoading)
    }

    @Test(arguments: ["auth/login", "available-permissions", "version"], [false, true])
    func switchingServerRetiresLoginAndBootstrap(_ delayedPath: String, logout: Bool) async throws {
        let gate = SessionGate()
        let tokens = InMemoryTokenStore()
        let response = LoginResponse(token: "old", refreshToken: "old-refresh", expiresAt: .distantFuture, user: User(id: "old-user", username: "old-user", roleAssignments: []))
        let loginData = Data("{\"success\":true,\"data\":".utf8)
            + (try ArcaneJSON.makeEncoder().encode(response)) + Data("}".utf8)
        let savedURL = UserDefaults.standard.string(forKey: "arcane.serverURL")
        defer { UserDefaults.standard.set(savedURL, forKey: "arcane.serverURL") }
        let manager = ArcaneClientManager(serverURL: "https://localhost", sessionFactory: { _ in
            LifecycleURLProtocol.session { request in
                if request.url?.path.hasSuffix(delayedPath) == true { await gate.suspend() }
                if request.url?.path.hasSuffix("auth/login") == true { return loginData }
                return Data(#"{"success":true,"data":[]}"#.utf8)
            }
        }, tokenStoreFactory: { _ in tokens })
        let pending = Task { await manager.login(username: "old-user", password: "password") }
        defer { pending.cancel() }
        try #require(await gate.waitUntilStarted(), "Authentication did not reach \(delayedPath): \(manager.errorMessage ?? "no error")")
        if logout { await manager.logout() }
        else { manager.configure(serverURL: "https://127.0.0.1") }
        let nextClient = manager.client?.transport
        await gate.release()
        await pending.value
        #expect(manager.serverURL == (logout ? "https://localhost" : "https://127.0.0.1"))
        #expect(manager.currentUser == nil)
        #expect(manager.authState == .login)
        #expect(manager.client?.transport === nextClient)
        #expect(!manager.isLoading)
        if logout { #expect(try await tokens.loadTokens() == nil) }
    }
}
