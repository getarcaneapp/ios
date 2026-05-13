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

    func listProjectsPage(
        envID: EnvironmentID,
        start: Int = 0,
        limit: Int = 50,
        archivedOnly: Bool = false
    ) async throws -> ProjectListPage {
        var query = [
            URLQueryItem(name: "start", value: "\(start)"),
            URLQueryItem(name: "limit", value: "\(limit)")
        ]
        if archivedOnly {
            query.append(URLQueryItem(name: "archived", value: "true"))
        }
        let path = rest.environmentPath(envID, "projects")
        let raw = try await transport.rawRequest(path, query: query, body: Optional<String>.none)
        do {
            return try ArcaneJSON.makeDecoder().decode(ProjectListPage.self, from: raw)
        } catch {
            throw ArcaneError.decoding(String(describing: error))
        }
    }

    func listAllProjects(
        envID: EnvironmentID,
        archivedOnly: Bool = false,
        pageSize: Int = 100
    ) async throws -> [Project] {
        var start = 0
        var allProjects: [Project] = []

        while true {
            let page = try await listProjectsPage(
                envID: envID,
                start: start,
                limit: pageSize,
                archivedOnly: archivedOnly
            )
            allProjects.append(contentsOf: page.data)

            if page.data.isEmpty || page.pagination.currentPage >= page.pagination.totalPages {
                return allProjects
            }

            start += max(Int(page.pagination.itemsPerPage), pageSize)
        }
    }

    func listImagesPage(
        envID: EnvironmentID,
        start: Int = 0,
        limit: Int = 50
    ) async throws -> ImageListPage {
        let query = [
            URLQueryItem(name: "start", value: "\(start)"),
            URLQueryItem(name: "limit", value: "\(limit)")
        ]
        let path = rest.environmentPath(envID, "images")
        let raw = try await transport.rawRequest(path, query: query, body: Optional<String>.none)
        do {
            return try ArcaneJSON.makeDecoder().decode(ImageListPage.self, from: raw)
        } catch {
            throw ArcaneError.decoding(String(describing: error))
        }
    }

    func listNetworksPage(
        envID: EnvironmentID,
        start: Int = 0,
        limit: Int = 50
    ) async throws -> NetworkListPage {
        let query = [
            URLQueryItem(name: "start", value: "\(start)"),
            URLQueryItem(name: "limit", value: "\(limit)")
        ]
        let path = rest.environmentPath(envID, "networks")
        let raw = try await transport.rawRequest(path, query: query, body: Optional<String>.none)
        do {
            return try ArcaneJSON.makeDecoder().decode(NetworkListPage.self, from: raw)
        } catch {
            throw ArcaneError.decoding(String(describing: error))
        }
    }

    func listVolumesPage(
        envID: EnvironmentID,
        start: Int = 0,
        limit: Int = 50,
        includeInternal: Bool = false
    ) async throws -> VolumeListPage {
        var query = [
            URLQueryItem(name: "start", value: "\(start)"),
            URLQueryItem(name: "limit", value: "\(limit)")
        ]
        if includeInternal {
            query.append(URLQueryItem(name: "includeInternal", value: "true"))
        }
        let path = rest.environmentPath(envID, "volumes")
        let raw = try await transport.rawRequest(path, query: query, body: Optional<String>.none)
        do {
            return try ArcaneJSON.makeDecoder().decode(VolumeListPage.self, from: raw)
        } catch {
            throw ArcaneError.decoding(String(describing: error))
        }
    }
}
