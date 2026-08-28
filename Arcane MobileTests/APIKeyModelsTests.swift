import Arcane
import Foundation
import XCTest

@testable import Arcane_Mobile

nonisolated final class APIKeyModelsTests: XCTestCase {
    func testLegacyMutationOmitsV2Permissions() throws {
        let request = APIKeyMutationRequest(
            name: "deploy",
            description: nil,
            expiresAt: nil,
            permissions: nil
        )

        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["name"] as? String, "deploy")
        XCTAssertNil(object["permissions"])
        XCTAssertNil(object["expiresAt"])
    }

    func testV2MutationEncodesPermissionGrants() throws {
        let request = APIKeyMutationRequest(
            name: "deploy",
            description: "Deployment automation",
            expiresAt: nil,
            permissions: [ApiKeyPermissionGrant(permission: "projects:update")]
        )

        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let permissions = try XCTUnwrap(object["permissions"] as? [[String: Any]])

        XCTAssertEqual(permissions.count, 1)
        XCTAssertEqual(permissions[0]["permission"] as? String, "projects:update")
        XCTAssertNil(permissions[0]["environmentId"])
    }

    func testServerMetadataDecodesV2Fields() throws {
        let data = Data(
            #"{"kind":"scoped","isBootstrap":true,"permissions":[{"permission":"containers:list"}]}"#.utf8
        )

        let metadata = try JSONDecoder().decode(APIKeyServerMetadata.self, from: data)

        XCTAssertEqual(metadata.kind, "scoped")
        XCTAssertEqual(metadata.isBootstrap, true)
        XCTAssertEqual(metadata.permissions?.map(\.permission), ["containers:list"])
    }

    func testServerMetadataAcceptsLegacyPayload() throws {
        let metadata = try JSONDecoder().decode(APIKeyServerMetadata.self, from: Data("{}".utf8))

        XCTAssertNil(metadata.kind)
        XCTAssertNil(metadata.isBootstrap)
        XCTAssertNil(metadata.permissions)
    }
}
