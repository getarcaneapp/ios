import Arcane
import Foundation
import Testing

@testable import Arcane_Mobile

@Suite
struct APIKeyModelsTests {
    @Test
    func legacyMutationOmitsV2Permissions() throws {
        let request = APIKeyMutationRequest(
            name: "deploy",
            description: nil,
            expiresAt: nil,
            permissions: nil
        )

        let data = try JSONEncoder().encode(request)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["name"] as? String == "deploy")
        #expect(object["permissions"] == nil)
        #expect(object["expiresAt"] == nil)
    }

    @Test
    func v2MutationEncodesPermissionGrants() throws {
        let request = APIKeyMutationRequest(
            name: "deploy",
            description: "Deployment automation",
            expiresAt: nil,
            permissions: [ApiKeyPermissionGrant(permission: "projects:update")]
        )

        let data = try JSONEncoder().encode(request)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let permissions = try #require(object["permissions"] as? [[String: Any]])

        #expect(permissions.count == 1)
        #expect(permissions[0]["permission"] as? String == "projects:update")
        #expect(permissions[0]["environmentId"] == nil)
    }

    @Test
    func serverMetadataDecodesV2Fields() throws {
        let data = Data(
            #"{"kind":"scoped","isBootstrap":true,"permissions":[{"permission":"containers:list"}]}"#.utf8
        )

        let metadata = try JSONDecoder().decode(APIKeyServerMetadata.self, from: data)

        #expect(metadata.kind == "scoped")
        #expect(metadata.isBootstrap == true)
        #expect(metadata.permissions?.map(\.permission) == ["containers:list"])
    }

    @Test
    func serverMetadataAcceptsLegacyPayload() throws {
        let metadata = try JSONDecoder().decode(APIKeyServerMetadata.self, from: Data("{}".utf8))

        #expect(metadata.kind == nil)
        #expect(metadata.isBootstrap == nil)
        #expect(metadata.permissions == nil)
    }
}
