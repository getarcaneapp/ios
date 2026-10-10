import Arcane
import Foundation

nonisolated enum FleetResourceKind: String, CaseIterable, Sendable {
    case containers, projects, images, networks, volumes, ports, jobs, gitOps, vulnerabilities, topology

    @MainActor init?(tab: AppTab) {
        switch tab {
        case .containers: self = .containers
        case .projects: self = .projects
        case .images: self = .images
        case .networks: self = .networks
        case .volumes: self = .volumes
        case .ports: self = .ports
        case .jobs: self = .jobs
        case .gitOps: self = .gitOps
        case .imageVulnerabilities: self = .vulnerabilities
        case .networkTopology: self = .topology
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .gitOps: "GitOps"
        case .topology: "Network Topology"
        default: rawValue.capitalized
        }
    }
}

nonisolated enum FleetResource: Identifiable, Sendable {
    case container(ContainerSummary)
    case project(ProjectDetails)
    case image(ImageSummary)
    case network(NetworkSummary)
    case volume(Volume)
    case port(PortMapping)
    case job(JobStatus)
    case gitOps(DynamicResource)
    case vulnerability(Arcane.VulnerabilityWithImage)
    case topology

    var id: String {
        switch self {
        case .container(let item): item.id
        case .project(let item): item.id
        case .image(let item): item.id
        case .network(let item): item.id
        case .volume(let item): item.id
        case .port(let item): item.id
        case .job(let item): item.id
        case .gitOps(let item): item.id
        case .vulnerability(let item):
            [item.imageId, item.vulnerabilityId, item.pkgName, item.installedVersion].joined(separator: "\u{0}")
        case .topology: "topology"
        }
    }

    var searchText: String {
        switch self {
        case .container(let item): item.names.joined(separator: " ") + " " + item.image
        case .project(let item): item.name
        case .image(let item): item.repoTags.joined(separator: " ") + " " + item.id
        case .network(let item): item.name
        case .volume(let item): item.name
        case .port(let item): item.containerName + " " + String(item.containerPort) + " " + String(item.hostPort ?? 0)
        case .job(let item): item.name
        case .gitOps(let item): item.title
        case .vulnerability(let item): item.vulnerabilityId + " " + item.imageName + " " + item.pkgName
        case .topology: "Network topology"
        }
    }
}

nonisolated struct FleetResourceBucket: Identifiable, Sendable {
    let id: String
    let name: String
    var resources: [FleetResource] = []
    var imageUpdates: [String: ImageUpdateResponse] = [:]
    var error: String?
    var isLoading = true
    var environmentID: EnvironmentID { EnvironmentID(rawValue: id) }
}

nonisolated struct FleetResourceListItem: Identifiable, Sendable {
    let resource: FleetResource
    let bucket: FleetResourceBucket
    var id: [String] { [bucket.id, resource.id] }
}
