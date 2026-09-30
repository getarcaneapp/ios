import Arcane
import Foundation

extension ContainerDetails {
    var navigationSummary: ContainerSummary {
        ContainerSummary(
            id: id,
            names: [name],
            image: image,
            imageId: imageId,
            command: config.cmd?.joined(separator: " ") ?? "",
            created: ArcaneDateFormatting.date(fromISO8601: created)
                .flatMap { Int64(exactly: $0.timeIntervalSince1970.rounded(.towardZero)) } ?? 0,
            ports: ports,
            labels: labels ?? [:],
            state: state.status,
            status: state.status,
            hostConfig: hostConfig,
            networkSettings: networkSettings,
            mounts: mounts,
            iconLightUrl: iconLightUrl,
            iconDarkUrl: iconDarkUrl,
            redeployDisabled: redeployDisabled
        )
    }
}
