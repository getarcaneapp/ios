import Foundation
import Arcane

enum NDJSONStream {
    static func stream<T: Decodable & Sendable>(
        _ type: T.Type,
        client: ArcaneClient,
        serverURL: URL,
        path: String,
        method: String = "POST",
        body: Data? = nil
    ) async throws -> AsyncThrowingStream<T, Error> {
        let url = apiURL(serverURL: serverURL, path: path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/x-json-stream, application/x-ndjson, application/json", forHTTPHeaderField: "Accept")
        for (key, value) in try await client.authManager.authenticationHeaders() {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            var snippet = Data()
            for try await byte in bytes {
                snippet.append(byte)
                if snippet.count > 4096 { break }
            }
            let message = String(data: snippet, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw NDJSONError(statusCode: http.statusCode, message: message)
        }

        let decoder = JSONDecoder()
        return AsyncThrowingStream<T, Error> { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { continue }
                        if let element = try? decoder.decode(T.self, from: data) {
                            continuation.yield(element)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func apiURL(serverURL: URL, path: String) -> URL {
        let trimmedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else {
            return serverURL.appendingPathComponent("api/" + trimmedPath)
        }
        var basePath = components.path
        if basePath.hasSuffix("/") { basePath.removeLast() }
        if !basePath.hasSuffix("/api") {
            basePath += "/api"
        }
        components.path = basePath + "/" + trimmedPath
        return components.url ?? serverURL
    }
}

struct NDJSONError: LocalizedError {
    let statusCode: Int
    let message: String

    var errorDescription: String? {
        if message.isEmpty { return "HTTP \(statusCode)" }
        return message
    }
}
