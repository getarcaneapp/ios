import Foundation
#if canImport(UIKit)
import UIKit
#endif

struct DemoSession {
    let sessionID: String
    let endsAt: Date
    let username: String
    let password: String
}

enum DemoError: Error, LocalizedError {
    case provisioningFailed
    case decoding
    case network(Error)

    var errorDescription: String? {
        switch self {
        case .provisioningFailed:
            return "The demo server couldn't spin up an instance. Try again in a moment."
        case .decoding:
            return "The demo server returned an unexpected response."
        case .network(let underlying):
            return "Couldn't reach the demo server: \(underlying.localizedDescription)"
        }
    }
}

@MainActor
final class DemoService {
    static let shared = DemoService()

    static let demoBaseURL = URL(string: "https://demo.getarcane.app")!

    private var heartbeatTask: Task<Void, Never>?
    private var lifecycleObservers: [NSObjectProtocol] = []

    private init() {}

    // MARK: - Provisioning

    func startInstance() async throws -> DemoSession {
        var request = URLRequest(url: Self.demoBaseURL.appendingPathComponent("demo-kuma/start-instance"))
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw DemoError.network(error)
        }

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw DemoError.provisioningFailed
        }

        struct Payload: Decodable {
            let ok: Bool
            let sessionID: String
            let endSessionTime: TimeInterval
            let credentials: Credentials
            struct Credentials: Decodable {
                let username: String
                let password: String
            }
        }

        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw DemoError.decoding
        }

        guard payload.ok else { throw DemoError.provisioningFailed }

        let endsAt = Date(timeIntervalSince1970: payload.endSessionTime / 1000.0)

        if let cookie = HTTPCookie(properties: [
            .domain: Self.demoBaseURL.host ?? "demo.getarcane.app",
            .path: "/",
            .name: "session-id",
            .value: payload.sessionID,
            .secure: "TRUE",
            .expires: endsAt,
        ]) {
            HTTPCookieStorage.shared.setCookie(cookie)
        }

        return DemoSession(
            sessionID: payload.sessionID,
            endsAt: endsAt,
            username: payload.credentials.username,
            password: payload.credentials.password
        )
    }

    // MARK: - Heartbeat

    func startHeartbeat() {
        stopHeartbeat()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                if Task.isCancelled { break }
                await self?.sendHeartbeat()
            }
        }
        installLifecycleObservers()
    }

    func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        removeLifecycleObservers()
    }

    private func sendHeartbeat() async {
        var request = URLRequest(url: Self.demoBaseURL.appendingPathComponent("demo-kuma/heartbeat"))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        _ = try? await URLSession.shared.data(for: request)
    }

    // MARK: - End session

    func endSession() async {
        stopHeartbeat()

        var request = URLRequest(url: Self.demoBaseURL.appendingPathComponent("demo-kuma/end-session"))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        _ = try? await URLSession.shared.data(for: request)

        if let cookies = HTTPCookieStorage.shared.cookies(for: Self.demoBaseURL) {
            for cookie in cookies where cookie.name == "session-id" {
                HTTPCookieStorage.shared.deleteCookie(cookie)
            }
        }
    }

    // MARK: - Lifecycle (pause heartbeat in background)

    private func installLifecycleObservers() {
        #if canImport(UIKit)
        removeLifecycleObservers()
        let center = NotificationCenter.default
        let resign = center.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.heartbeatTask?.cancel() }
        }
        let active = center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.heartbeatTask == nil || self.heartbeatTask?.isCancelled == true {
                    self.heartbeatTask = Task { [weak self] in
                        await self?.sendHeartbeat()
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(15))
                            if Task.isCancelled { break }
                            await self?.sendHeartbeat()
                        }
                    }
                }
            }
        }
        lifecycleObservers = [resign, active]
        #endif
    }

    private func removeLifecycleObservers() {
        let center = NotificationCenter.default
        for token in lifecycleObservers {
            center.removeObserver(token)
        }
        lifecycleObservers = []
    }
}
