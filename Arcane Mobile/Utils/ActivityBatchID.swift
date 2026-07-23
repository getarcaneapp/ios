import Foundation
import Arcane

nonisolated enum ActivityBatchID {
    static func make() -> String {
        UUID().uuidString.lowercased()
    }

    static func requestOptions() throws -> ArcaneRequestOptions {
        try ArcaneRequestOptions(activityBatchID: make())
    }

    static func scopedClient(_ client: ArcaneClient) throws -> ArcaneClient {
        client.withRequestOptions(try requestOptions())
    }
}
