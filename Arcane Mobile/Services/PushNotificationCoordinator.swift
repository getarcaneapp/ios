import SwiftUI
import Observation
import UserNotifications
import Security
import Arcane

/// Owns the device side of native push: APNs registration, enrollment and
/// pairing with the push relay, the per-server device record on the Arcane
/// server, and the Keychain-backed credentials that tie them together.
///
/// The relay is talked to over a dedicated ephemeral session that carries no
/// Arcane cookies or tokens; the relay never learns the server URL.
@MainActor
@Observable
final class PushNotificationCoordinator {
    static let shared = PushNotificationCoordinator()

    enum PushError: LocalizedError {
        case serverDisabled
        case notAuthorized
        case noDeviceToken
        case relay(Int, String)
        case notSignedIn

        var errorDescription: String? {
            switch self {
            case .serverDisabled: return "Your Arcane admin hasn't enabled mobile push notifications."
            case .notAuthorized: return "Notifications are turned off for Arcane in iOS Settings."
            case .noDeviceToken: return "Couldn't register this device with Apple Push Notifications."
            case .relay(let status, let message): return "Push relay error (\(status)): \(message)"
            case .notSignedIn: return "Sign in to enable push notifications."
            }
        }
    }

    nonisolated struct ServerBinding: Codable, Equatable {
        var recipientId: String
        var channelId: String
        var deviceId: String
    }

    nonisolated struct Credentials: Codable, Equatable {
        var relayURL: String
        var installationId: String
        var installationSecret: String
        var deviceToken: String
        var apnsEnvironment: String
        var bindings: [String: ServerBinding] = [:]
    }

    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    private(set) var isBusy = false
    private(set) var serverStatus: MobilePushStatus?
    private(set) var errorMessage: String?
    private(set) var credentials: Credentials?

    private var latestDeviceToken: String?
    private var registrationError: Error?
    private let relaySession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    private init() {
        credentials = PushKeychain.load()
    }

    // MARK: - State

    func isEnabled(for origin: String?) -> Bool {
        binding(for: origin) != nil
    }

    func binding(for origin: String?) -> ServerBinding? {
        guard let origin else { return nil }
        return credentials?.bindings[origin]
    }

    var isAuthorizationDenied: Bool { authorizationStatus == .denied }

    func refreshAuthorizationStatus() async {
        authorizationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Re-registers with APNs on every launch where the user already granted
    /// permission so token rotations reach the relay.
    func registerIfAuthorized() async {
        await refreshAuthorizationStatus()
        guard authorizationStatus == .authorized || authorizationStatus == .provisional else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    func refreshServerStatus(manager: ArcaneClientManager) async {
        guard manager.supportsMobilePush, let client = manager.client else {
            serverStatus = nil
            return
        }
        serverStatus = try? await client.mobilePush.status()
        // The server forgot this device (admin disabled push, or it was pruned)
        // — drop the stale local binding so the toggle reads correctly.
        if let status = serverStatus, let origin = manager.serverOrigin,
           let binding = binding(for: origin),
           !status.enabled || !status.devices.contains(where: { $0.id == binding.deviceId }) {
            credentials?.bindings.removeValue(forKey: origin)
            persist()
        }
    }

    // MARK: - APNs callbacks

    func didRegister(deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        latestDeviceToken = token
        registrationError = nil
        let environment = Self.detectAPNSEnvironment()
        guard let creds = credentials, creds.deviceToken != token || creds.apnsEnvironment != environment else { return }
        var updated = creds
        updated.deviceToken = token
        updated.apnsEnvironment = environment
        Task {
            do {
                try await updateRelayToken(updated)
                credentials = updated
                persist()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func didFailToRegister(error: Error) {
        registrationError = error
    }

    /// Polls for the APNs token the AppDelegate hands us; registration is
    /// asynchronous and has no completion handler of its own.
    private func awaitDeviceToken() async throws -> String {
        if let latestDeviceToken { return latestDeviceToken }
        registrationError = nil
        UIApplication.shared.registerForRemoteNotifications()
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(250))
            if let latestDeviceToken { return latestDeviceToken }
            if let registrationError { throw registrationError }
        }
        throw PushError.noDeviceToken
    }

    // MARK: - Enable / disable

    func enable(manager: ArcaneClientManager) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            guard let client = manager.client, let origin = manager.serverOrigin else { throw PushError.notSignedIn }
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            await refreshAuthorizationStatus()
            guard granted else { throw PushError.notAuthorized }

            let status = try await client.mobilePush.status()
            serverStatus = status
            guard status.enabled else { throw PushError.serverDisabled }

            let token = try await awaitDeviceToken()
            var creds = try await ensureInstallation(relayURL: status.relayUrl, deviceToken: token)

            let pairing = try await client.mobilePush.pairingToken()
            let paired: PairResponse = try await relayRequest(
                creds, "POST", "/v1/pair",
                body: ["pairingToken": pairing.token],
                authorized: true
            )
            let device = try await client.mobilePush.registerDevice(
                MobilePushRegisterDevice(recipientId: paired.recipientId, label: UIDevice.current.name)
            )
            creds.bindings[origin] = ServerBinding(recipientId: paired.recipientId, channelId: paired.channelId, deviceId: device.id)
            credentials = creds
            persist()
            serverStatus = try? await client.mobilePush.status()
            showToast(.success("Push notifications enabled"))
        } catch {
            let message = (error as? ArcaneError).map { "Arcane: \($0)" } ?? error.localizedDescription
            errorMessage = message
            showToast(.error(message))
        }
    }

    func disable(manager: ArcaneClientManager) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        await tearDown(client: manager.client, origin: manager.serverOrigin)
        serverStatus = try? await manager.client?.mobilePush.status()
        showToast(.info("Push notifications disabled"))
    }

    /// Unpairs at the relay first, then removes the server record. Safe to
    /// call with a client whose session is about to end.
    func tearDown(client: ArcaneClient?, origin: String?) async {
        guard let origin, let creds = credentials, let binding = creds.bindings[origin] else { return }
        var updated = creds
        updated.bindings.removeValue(forKey: origin)
        credentials = updated
        persist()
        _ = try? await relayRequestVoid(creds, "POST", "/v1/unpair", body: ["recipientId": binding.recipientId])
        try? await client?.mobilePush.deleteDevice(id: binding.deviceId)
    }

    // MARK: - Incoming notifications

    func handleForeground(userInfo: [AnyHashable: Any], title: String) {
        guard MobilePushPayload(userInfo: userInfo) != nil else { return }
        showToast(.info(title))
    }

    /// Routes a tapped notification. Ignored unless the payload's channel is the
    /// one paired for the currently configured server.
    func handleTap(userInfo: [AnyHashable: Any], manager: ArcaneClientManager) {
        guard let payload = MobilePushPayload(userInfo: userInfo),
              let binding = binding(for: manager.serverOrigin),
              binding.channelId == payload.channelId
        else { return }
        QuickActionRouter.shared.handle(route: payload.route)
    }

    // MARK: - Relay client

    private struct InstallationResponse: Decodable { let installationId: String; let installationSecret: String }
    private struct PairResponse: Decodable { let recipientId: String; let channelId: String }
    private struct RelayError: Decodable { struct Body: Decodable { let code: String; let message: String }; let error: Body }

    private func ensureInstallation(relayURL: String, deviceToken: String) async throws -> Credentials {
        let environment = Self.detectAPNSEnvironment()
        if let creds = credentials, creds.relayURL == relayURL {
            if creds.deviceToken != deviceToken || creds.apnsEnvironment != environment {
                var updated = creds
                updated.deviceToken = deviceToken
                updated.apnsEnvironment = environment
                try await updateRelayToken(updated)
                credentials = updated
                persist()
                return updated
            }
            return creds
        }
        let bootstrap = Credentials(relayURL: relayURL, installationId: "", installationSecret: "", deviceToken: deviceToken, apnsEnvironment: environment)
        let created: InstallationResponse = try await relayRequest(
            bootstrap, "POST", "/v1/installations",
            body: [
                "platform": "apns",
                "apnsEnvironment": environment,
                "deviceToken": deviceToken,
                "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            ],
            authorized: false
        )
        let creds = Credentials(relayURL: relayURL, installationId: created.installationId, installationSecret: created.installationSecret, deviceToken: deviceToken, apnsEnvironment: environment)
        credentials = creds
        persist()
        return creds
    }

    private func updateRelayToken(_ creds: Credentials) async throws {
        try await relayRequestVoid(
            creds, "PUT", "/v1/installations/\(creds.installationId)/token",
            body: ["deviceToken": creds.deviceToken, "apnsEnvironment": creds.apnsEnvironment]
        )
    }

    private func relayRequest<T: Decodable>(
        _ creds: Credentials, _ method: String, _ path: String,
        body: [String: String], authorized: Bool
    ) async throws -> T {
        let data = try await relayData(creds, method, path, body: body, authorized: authorized)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func relayRequestVoid(_ creds: Credentials, _ method: String, _ path: String, body: [String: String]) async throws {
        _ = try await relayData(creds, method, path, body: body, authorized: true)
    }

    private func relayData(_ creds: Credentials, _ method: String, _ path: String, body: [String: String], authorized: Bool) async throws -> Data {
        guard let url = URL(string: creds.relayURL + path) else { throw PushError.relay(0, "invalid relay URL") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        if authorized {
            request.setValue("Bearer \(creds.installationId).\(creds.installationSecret)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await relaySession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(RelayError.self, from: data))?.error.message
                ?? String(data: data, encoding: .utf8) ?? ""
            throw PushError.relay(status, message)
        }
        return data
    }

    private func persist() {
        PushKeychain.save(credentials)
    }

    nonisolated static func detectAPNSEnvironment() -> String {
        #if targetEnvironment(simulator)
        return "sandbox"
        #else
        guard let path = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision"),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let text = String(data: data, encoding: .isoLatin1),
              let keyRange = text.range(of: "<key>aps-environment</key>"),
              let valueStart = text.range(of: "<string>", range: keyRange.upperBound..<text.endIndex),
              let valueEnd = text.range(of: "</string>", range: valueStart.upperBound..<text.endIndex)
        else { return "production" }
        return text[valueStart.upperBound..<valueEnd.lowerBound] == "development" ? "sandbox" : "production"
        #endif
    }
}

/// Single generic-password item holding the relay credentials; private to the
/// app (the widget extension never sends pushes).
nonisolated private enum PushKeychain {
    private static let service = "com.arcane.mobile.push"
    private static let account = "relay"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func load() -> PushNotificationCoordinator.Credentials? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(PushNotificationCoordinator.Credentials.self, from: data)
    }

    static func save(_ credentials: PushNotificationCoordinator.Credentials?) {
        guard let credentials, let data = try? JSONEncoder().encode(credentials) else {
            _ = SecItemDelete(baseQuery as CFDictionary)
            return
        }
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        guard status == errSecItemNotFound else { return }
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        _ = SecItemAdd(add as CFDictionary, nil)
    }
}
