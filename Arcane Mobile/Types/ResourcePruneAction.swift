import Arcane
import Foundation

enum ResourcePruneAction: String, CaseIterable, Identifiable {
    case containers, images, unusedImages, volumes, networks

    var id: String { rawValue }

    var title: String {
        switch self {
        case .containers: "Prune Stopped Containers"
        case .images: "Prune Dangling Images"
        case .unusedImages: "Prune All Unused Images"
        case .volumes: "Prune Unused Volumes"
        case .networks: "Prune Networks"
        }
    }

    var message: String {
        switch self {
        case .containers: "Remove all stopped containers. This cannot be undone."
        case .images: "Remove all dangling images. This cannot be undone."
        case .unusedImages: "Remove all images not used by a container. This cannot be undone."
        case .volumes: "All unused volumes will be permanently deleted."
        case .networks: "Remove all unused networks."
        }
    }

    /// Confirmation text when the prune runs on every enabled environment.
    var allEnvironmentsMessage: String {
        "\(message) This runs on every enabled environment."
    }

    var permission: String {
        switch self {
        case .containers: Permission.System.prune
        case .images, .unusedImages: Permission.Images.prune
        case .volumes: Permission.Volumes.prune
        case .networks: Permission.Networks.prune
        }
    }

    var mutationKind: ResourceMutationStore.Kind {
        switch self {
        case .containers: .containers
        case .images, .unusedImages: .images
        case .volumes: .volumes
        case .networks: .networks
        }
    }

    func perform(client: ArcaneClient, environmentID: EnvironmentID) async throws {
        switch self {
        case .containers:
            // Arcane exposes container pruning through the system endpoint.
            // Only containers are selected; no other resource can be pruned.
            let result = try await client.system.prune(
                PruneAllRequest(containers: .init(mode: .stopped)), envID: environmentID)
            guard result.success else {
                throw ArcaneError.transport(result.errors?.joined(separator: "\n") ?? "Container prune failed")
            }
        case .images:
            _ = try await client.images.prune(envID: environmentID, mode: "dangling")
        case .unusedImages:
            _ = try await client.images.prune(envID: environmentID, mode: "all")
        case .volumes:
            _ = try await client.volumes.prune(envID: environmentID)
        case .networks:
            _ = try await client.networks.prune(envID: environmentID)
        }
    }

    var resourceName: String { self == .unusedImages ? "images" : rawValue }
}
