import Foundation
import Arcane

extension ArcaneClient {
    func pauseContainer(envID: EnvironmentID, id: String) async throws {
        let path = rest.environmentPath(envID, "containers/\(id)/pause")
        let _: MessageResponse = try await rest.post(path, body: String?.none)
    }

    func unpauseContainer(envID: EnvironmentID, id: String) async throws {
        let path = rest.environmentPath(envID, "containers/\(id)/unpause")
        let _: MessageResponse = try await rest.post(path, body: String?.none)
    }

    func killContainer(envID: EnvironmentID, id: String, signal: String = "SIGKILL") async throws {
        var components = URLComponents()
        components.path = ""
        components.queryItems = [URLQueryItem(name: "signal", value: signal)]
        let query = components.percentEncodedQuery.map { "?\($0)" } ?? ""
        let path = rest.environmentPath(envID, "containers/\(id)/kill") + query
        let _: MessageResponse = try await rest.post(path, body: String?.none)
    }

    func renameContainer(envID: EnvironmentID, id: String, newName: String) async throws {
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "name", value: newName)]
        let query = components.percentEncodedQuery.map { "?\($0)" } ?? ""
        let path = rest.environmentPath(envID, "containers/\(id)/rename") + query
        let _: MessageResponse = try await rest.post(path, body: String?.none)
    }
}
