import Arcane
import Foundation
import Observation

@MainActor @Observable
final class FleetResourcesStore {
    private(set) var buckets: [FleetResourceBucket] = []
    private(set) var isLoading = false
    private var generation = 0
    private var clientIdentity: ObjectIdentifier?
    private var resourceKind: FleetResourceKind?

    func load(
        kind: FleetResourceKind, environments: [Arcane.Environment], client: ArcaneClient,
        acceptsResult: @MainActor () -> Bool
    ) async {
        generation &+= 1
        let request = generation
        let identity = ObjectIdentifier(client.transport)
        let previous =
            clientIdentity == identity && resourceKind == kind
            ? Dictionary(uniqueKeysWithValues: buckets.map { ($0.id, $0) }) : [:]
        clientIdentity = identity
        resourceKind = kind
        // Keep existing rows visible while the same connection refreshes.
        // A new account/client or resource kind starts with an empty list.
        buckets = environments.filter(\.enabled).sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
        .map { environment in
            var bucket = FleetResourceBucket(id: environment.id, name: environment.displayName)
            if let existing = previous[environment.id] {
                bucket.resources = existing.resources
                bucket.imageUpdates = existing.imageUpdates
            }
            bucket.isLoading = true
            return bucket
        }
        let targets = buckets
        isLoading = true
        defer { if request == generation { isLoading = false } }
        await withTaskGroup(of: FleetResourceBucket.self) { group in
            var next = 0
            func enqueue() {
                guard next < targets.count, !Task.isCancelled else { return }
                let target = targets[next]
                next += 1
                group.addTask { await Self.fetch(kind: kind, target: target, client: client) }
            }
            for _ in 0..<min(4, targets.count) { enqueue() }
            while let result = await group.next() {
                guard !Task.isCancelled, request == generation, acceptsResult() else {
                    group.cancelAll()
                    return
                }
                if let index = buckets.firstIndex(where: { $0.id == result.id }) { buckets[index] = result }
                enqueue()
            }
        }
    }

    nonisolated private static func fetch(kind: FleetResourceKind, target: FleetResourceBucket, client: ArcaneClient)
        async -> FleetResourceBucket
    {
        var result = target
        do {
            try Task.checkCancellation()
            result.resources = try await resources(kind: kind, environmentID: target.environmentID, client: client)
            if kind == .images {
                let references = Array(
                    Set(
                        result.resources.flatMap { resource -> [String] in
                            guard case .image(let image) = resource else { return [] }
                            return image.repoTags.filter { $0 != "<none>:<none>" }
                        })
                ).sorted()
                result.imageUpdates = [:]
                // Bound each request and keep image rows usable when update metadata is unavailable.
                for start in stride(from: 0, to: references.count, by: 50) {
                    guard !Task.isCancelled else { break }
                    let batch = Array(references[start..<min(start + 50, references.count)])
                    if let info = try? await client.images.updateInfoByRefs(
                        envID: target.environmentID, imageRefs: batch)
                    {
                        result.imageUpdates.merge(ImageUpdateState.checkedResults(info)) { _, new in new }
                    }
                }
            }
            result.isLoading = false
            return result
        } catch {
            result.error = error.localizedDescription
            result.isLoading = false
            return result
        }
    }

    nonisolated static func resources(kind: FleetResourceKind, environmentID: EnvironmentID, client: ArcaneClient)
        async throws -> [FleetResource]
    {
        if kind == .topology { return [.topology] }
        if kind == .jobs { return try await client.jobs.list(envID: environmentID).jobs.map(FleetResource.job) }
        return try await PaginationLoader.collect { start, limit in
            try Task.checkCancellation()
            let query = SearchPaginationSort(start: start, limit: limit)
            switch kind {
            case .containers:
                let response = try await client.containers.list(envID: environmentID, query: query, includeHidden: true)
                return ResourcePage(items: response.data.map(FleetResource.container), pagination: response.pagination)
            case .projects:
                let response = try await client.projects.list(envID: environmentID, query: query)
                return ResourcePage(items: response.data.map(FleetResource.project), pagination: response.pagination)
            case .images:
                let response = try await client.images.list(envID: environmentID, query: query)
                return ResourcePage(items: response.data.map(FleetResource.image), pagination: response.pagination)
            case .networks:
                let response = try await client.networks.list(envID: environmentID, query: query)
                return ResourcePage(items: response.data.map(FleetResource.network), pagination: response.pagination)
            case .volumes:
                let response = try await client.volumes.list(envID: environmentID, query: query)
                return ResourcePage(items: response.data.map(FleetResource.volume), pagination: response.pagination)
            case .ports:
                let response = try await client.ports.list(envID: environmentID, query: query)
                return ResourcePage(items: response.data.map(FleetResource.port), pagination: response.pagination)
            case .vulnerabilities:
                let response = try await client.vulnerabilities.listAll(envID: environmentID, query: query)
                return ResourcePage(
                    items: response.data.map(FleetResource.vulnerability), pagination: response.pagination)
            case .gitOps:
                let response: PaginatedResponse<DynamicResource> = try await client.rest.paginated(
                    client.rest.environmentPath(environmentID, "gitops-syncs"), start: start, limit: limit)
                return ResourcePage(items: response.data.map(FleetResource.gitOps), pagination: response.pagination)
            case .jobs, .topology:
                preconditionFailure("Nonpaginated resources are loaded before pagination")
            }
        }
    }
}
