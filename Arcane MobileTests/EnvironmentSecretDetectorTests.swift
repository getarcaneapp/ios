import XCTest

@testable import Arcane_Mobile

final class EnvironmentSecretDetectorTests: XCTestCase {
    func testParsesOnlyTheFirstAssignmentSeparator() {
        let variable = ParsedEnvironmentVariable(rawValue: "ACCESS_TOKEN=header.payload=signature")

        XCTAssertEqual(variable.name, "ACCESS_TOKEN")
        XCTAssertEqual(variable.value, "header.payload=signature")
        XCTAssertTrue(variable.isPotentialSecret)
    }

    func testSensitiveNamesAreDetected() {
        let names = [
            "PASSWORD",
            "POSTGRES_PASSWORD",
            "client-secret",
            "GITHUB_TOKEN",
            "API_KEY",
            "APPKEY",
            "DOCKER_AUTH_CONFIG",
            "WEBHOOK_URL",
        ]

        for name in names {
            XCTAssertTrue(
                EnvironmentSecretDetector.isPotentialSecret(name: name, value: "example-value"),
                name
            )
        }
    }

    func testSecretMetadataNamesStayVisible() {
        let names = [
            "PATH",
            "PWD",
            "PUBLIC_KEY",
            "PASSWORD_FILE",
            "TOKEN_ENDPOINT",
            "AUTH_METHOD",
            "AWS_ACCESS_KEY_ID",
            "DATABASE_URL",
        ]

        for name in names {
            XCTAssertFalse(
                EnvironmentSecretDetector.isPotentialSecret(name: name, value: "example-value"),
                name
            )
        }
    }

    func testStructuredSecretValuesAreDetectedWithNeutralNames() {
        let values = [
            "postgres://user:password@example.test/database",
            "Server=example.test;Password=example-value",
            "https://example.test/hook?sig=example-value",
            "-----BEGIN PRIVATE KEY-----\nexample\n-----END PRIVATE KEY-----",
            "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJleGFtcGxlIn0.c2lnbmF0dXJl",
            "github_pat_examplevalue",
        ]

        for value in values {
            XCTAssertTrue(
                EnvironmentSecretDetector.isPotentialSecret(name: "CONFIG", value: value),
                value
            )
        }
    }

    func testEmptyValuesAreNotMasked() {
        XCTAssertFalse(EnvironmentSecretDetector.isPotentialSecret(name: "TOKEN", value: ""))
        XCTAssertFalse(EnvironmentSecretDetector.isPotentialSecret(name: "PASSWORD", value: "  "))
    }
}
