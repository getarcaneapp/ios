import Foundation
import Arcane

enum ArcaneAPIHelpers {
    static func environmentPath(_ client: ArcaneClient, envID: EnvironmentID, _ suffix: String) -> String {
        client.rest.environmentPath(envID, suffix)
    }

    static func escapedPathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }

    static func queryPath(_ path: String, items: [URLQueryItem]) -> String {
        guard !items.isEmpty else { return path }
        var components = URLComponents()
        components.queryItems = items
        return path + (components.percentEncodedQuery.map { "?\($0)" } ?? "")
    }

    static func loadList(client: ArcaneClient, path: String) async throws -> [DynamicResource] {
        let raw = try await client.transport.rawRequest(path, body: Optional<String>.none)
        return try JSONDecoder().decode(DynamicListEnvelope.self, from: raw).items
    }

    static func loadObject(client: ArcaneClient, path: String) async throws -> DynamicResource {
        let raw = try await client.transport.rawRequest(path, body: Optional<String>.none)
        if let resource = try? JSONDecoder().decode(DynamicResource.self, from: raw) {
            return resource
        }
        let envelope = try JSONDecoder().decode(DynamicListEnvelope.self, from: raw)
        return envelope.items.first ?? DynamicResource(id: "response", values: [:])
    }

    static func send(client: ArcaneClient, path: String, method: BackendListAction.Method, body: Data? = nil) async throws -> Data {
        switch method {
        case .get:
            return try await client.transport.rawRequest(path, body: Optional<String>.none)
        case .post, .put, .patch, .delete:
            return try await client.transport.rawRequest(path, method: method.rawValue, body: body)
        }
    }

    static func formBody(values: [String: String], toggles: [String: Bool], fields: [BackendFormField]) throws -> Data {
        var object: [String: Any] = [:]
        for field in fields {
            switch field.type {
            case .toggle:
                object[field.id] = toggles[field.id, default: false]
            case .number:
                let raw = values[field.id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
                if let integer = Int(raw) {
                    object[field.id] = integer
                } else if let double = Double(raw) {
                    object[field.id] = double
                } else if !raw.isEmpty {
                    object[field.id] = raw
                }
            case .text, .secure, .multiline:
                let raw = values[field.id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
                if !raw.isEmpty {
                    object[field.id] = raw
                }
            }
        }
        return try JSONSerialization.data(withJSONObject: object)
    }
}
