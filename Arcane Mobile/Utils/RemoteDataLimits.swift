import Arcane
import Foundation

nonisolated enum RemoteDataLimits {
    static let maximumCollectionItems = 10_000
    static let maximumEnvironments = 250
    static let maximumTopologyNodes = 500
    static let maximumTopologyEdges = 2_000
    static let maximumUpdaterItems = 500
    static let maximumUpdaterStatusIDs = 200
    static let maximumTemplateRegistries = 500
    static let maximumResponseBytes = 8 * 1_024 * 1_024
    static let maximumInspectBytes = 4 * 1_024 * 1_024
    static let maximumTemplateBytes = 2 * 1_024 * 1_024
    static let maximumImageBytes = 5 * 1_024 * 1_024
    static let maximumStreamLineBytes = 16 * 1_024
    static let maximumTerminalFrameBytes = 256 * 1_024

    static func boundedData(
        client: ArcaneClient,
        path: String,
        maximumBytes: Int = maximumResponseBytes,
        method: String = "GET",
        body: Data? = nil,
        contentType: String? = nil,
        authorized: Bool = true,
        accept: String = "application/json"
    ) async throws -> Data {
        let (bytes, response) = try await client.transport.byteStream(
            path: path,
            method: method,
            body: body,
            contentType: contentType,
            accept: accept,
            authorized: authorized
        )
        guard (200..<300).contains(response.statusCode) else {
            throw RemoteDataLimitError.httpStatus(response.statusCode)
        }
        if response.expectedContentLength > Int64(maximumBytes) {
            throw RemoteDataLimitError.responseTooLarge(maximumBytes: maximumBytes)
        }

        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(min(maximumBytes, Int(response.expectedContentLength)))
        }
        for try await byte in bytes {
            guard data.count < maximumBytes else {
                throw RemoteDataLimitError.responseTooLarge(maximumBytes: maximumBytes)
            }
            data.append(byte)
        }
        return data
    }

    static func boundedAPIResponse<Value: Decodable & Sendable>(
        client: ArcaneClient,
        path: String,
        as type: Value.Type,
        maximumBytes: Int = maximumResponseBytes
    ) async throws -> Value {
        let data = try await boundedData(
            client: client,
            path: path,
            maximumBytes: maximumBytes
        )
        return try ArcaneJSON.makeDecoder().decode(APIResponse<Value>.self, from: data).data
    }

    static func boundedDirectResponse<Value: Decodable & Sendable>(
        client: ArcaneClient,
        path: String,
        as type: Value.Type,
        maximumBytes: Int = maximumResponseBytes
    ) async throws -> Value {
        let data = try await boundedData(client: client, path: path, maximumBytes: maximumBytes)
        return try ArcaneJSON.makeDecoder().decode(Value.self, from: data)
    }

    static func boundedContainerInspect(
        client: ArcaneClient,
        environmentID: EnvironmentID,
        containerID: String
    ) async throws -> ContainerDetails {
        let escapedID = ArcaneAPIHelpers.escapedPathComponent(containerID)
        return try await boundedAPIResponse(
            client: client,
            path: client.rest.environmentPath(environmentID, "containers/\(escapedID)"),
            as: ContainerDetails.self,
            maximumBytes: maximumInspectBytes
        )
    }

    static func boundedDockerInfo(
        client: ArcaneClient,
        environmentID: EnvironmentID
    ) async throws -> DockerInfo {
        try await boundedDirectResponse(
            client: client,
            path: client.rest.environmentPath(environmentID, "system/docker/info"),
            as: DockerInfo.self,
            maximumBytes: maximumInspectBytes
        )
    }

    static func boundedUpdaterResult(_ result: UpdaterResult) -> UpdaterResult {
        UpdaterResult(
            success: result.success,
            checked: nonnegative(result.checked),
            updated: nonnegative(result.updated),
            skipped: nonnegative(result.skipped),
            failed: nonnegative(result.failed),
            startTime: result.startTime.map { boundedText($0, maximumBytes: 256) },
            endTime: result.endTime.map { boundedText($0, maximumBytes: 256) },
            duration: boundedText(result.duration, maximumBytes: 256),
            items: result.items.prefix(maximumUpdaterItems).map { boundedUpdaterItem($0) },
            activityID: result.activityID.map { boundedText($0, maximumBytes: 512) }
        )
    }

    static func runBoundedUpdater(
        client: ArcaneClient,
        environmentID: EnvironmentID
    ) async throws -> UpdaterResult {
        let path = client.rest.environmentPath(environmentID, "updater/run")
        let data = try await boundedData(client: client, path: path, method: "POST")
        let result = try ArcaneJSON.makeDecoder().decode(APIResponse<UpdaterResult>.self, from: data).data
        return boundedUpdaterResult(result)
    }

    static func loadBoundedUpdaterStatus(
        client: ArcaneClient,
        environmentID: EnvironmentID
    ) async throws -> UpdaterStatus {
        let status = try await boundedAPIResponse(
            client: client,
            path: client.rest.environmentPath(environmentID, "updater/status"),
            as: UpdaterStatus.self
        )
        return boundedUpdaterStatus(status)
    }

    static func boundedUpdaterStatus(_ status: UpdaterStatus) -> UpdaterStatus {
        UpdaterStatus(
            updatingContainers: nonnegative(status.updatingContainers),
            updatingProjects: nonnegative(status.updatingProjects),
            containerIds: boundedIDs(status.containerIds),
            projectIds: boundedIDs(status.projectIds)
        )
    }

    private static func boundedUpdaterItem(_ item: UpdaterResourceResult) -> UpdaterResourceResult {
        UpdaterResourceResult(
            resourceId: boundedText(item.resourceId, maximumBytes: 512),
            resourceName: item.resourceName.map { boundedText($0, maximumBytes: 512) },
            resourceType: boundedText(item.resourceType, maximumBytes: 128),
            status: boundedText(item.status, maximumBytes: 128),
            updateAvailable: item.updateAvailable,
            updateApplied: item.updateApplied,
            oldImages: boundedImageMap(item.oldImages),
            newImages: boundedImageMap(item.newImages),
            error: item.error.map { boundedText($0, maximumBytes: maximumStreamLineBytes) },
            details: nil
        )
    }

    private static func boundedImageMap(_ map: [String: String]?) -> [String: String]? {
        guard let map else { return nil }
        return map.prefix(50).reduce(into: [:]) { result, entry in
            let key = boundedText(entry.key, maximumBytes: 512)
            if result[key] == nil {
                result[key] = boundedText(entry.value, maximumBytes: 512)
            }
        }
    }

    private static func boundedIDs(_ ids: [String]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for rawID in ids.prefix(maximumUpdaterStatusIDs) {
            let id = boundedText(rawID, maximumBytes: 512)
            if seen.insert(id).inserted { result.append(id) }
        }
        return result
    }

    static func boundedText(_ text: String, maximumBytes: Int) -> String {
        guard maximumBytes > 0, text.utf8.count > maximumBytes else {
            return maximumBytes > 0 ? text : ""
        }
        let marker = "\n… output truncated …"
        let contentLimit = max(0, maximumBytes - marker.utf8.count)
        var used = 0
        var result = String()
        result.reserveCapacity(min(text.count, contentLimit))
        for character in text {
            let bytes = String(character).utf8.count
            guard used + bytes <= contentLimit else { break }
            result.append(character)
            used += bytes
        }
        return result + marker
    }

    static func nonnegative(_ value: Int, maximum: Int = 1_000_000_000) -> Int {
        min(max(value, 0), maximum)
    }

    static func nonnegative(_ value: Int64, maximum: Int64 = 1_000_000_000_000_000) -> Int64 {
        min(max(value, 0), maximum)
    }

    static func saturatingAdd(_ lhs: Int, _ rhs: Int, maximum: Int = 1_000_000_000) -> Int {
        let left = nonnegative(lhs, maximum: maximum)
        let right = nonnegative(rhs, maximum: maximum)
        let (sum, overflow) = left.addingReportingOverflow(right)
        return overflow ? maximum : min(sum, maximum)
    }

    static func saturatingAdd(
        _ lhs: Int64,
        _ rhs: Int64,
        maximum: Int64 = 1_000_000_000_000_000
    ) -> Int64 {
        let left = nonnegative(lhs, maximum: maximum)
        let right = nonnegative(rhs, maximum: maximum)
        let (sum, overflow) = left.addingReportingOverflow(right)
        return overflow ? maximum : min(sum, maximum)
    }
}

nonisolated enum RemoteDataLimitError: LocalizedError, Sendable, Equatable {
    case collectionTooLarge(maximumItems: Int)
    case responseTooLarge(maximumBytes: Int)
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .collectionTooLarge(let maximumItems):
            "The server returned more than the supported limit of \(maximumItems) items."
        case .responseTooLarge(let maximumBytes):
            "The server response exceeded the \(ByteCountFormatter.string(fromByteCount: Int64(maximumBytes), countStyle: .file)) safety limit."
        case .httpStatus(let status):
            "The server returned HTTP \(status)."
        }
    }
}
