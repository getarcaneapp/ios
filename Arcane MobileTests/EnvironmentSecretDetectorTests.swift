import Testing

@testable import Arcane_Mobile

@Suite
struct EnvironmentSecretDetectorTests {
    @Test
    func parsesOnlyTheFirstAssignmentSeparator() {
        let variable = ParsedEnvironmentVariable(rawValue: "ACCESS_TOKEN=header.payload=signature")

        #expect(variable.name == "ACCESS_TOKEN")
        #expect(variable.value == "header.payload=signature")
        #expect(variable.isPotentialSecret)
    }

    @Test(arguments: [
        "PASSWORD",
        "POSTGRES_PASSWORD",
        "client-secret",
        "GITHUB_TOKEN",
        "API_KEY",
        "APPKEY",
        "DOCKER_AUTH_CONFIG",
        "WEBHOOK_URL",
    ])
    func sensitiveNamesAreDetected(name: String) {
        #expect(
            EnvironmentSecretDetector.isPotentialSecret(name: name, value: "example-value"),
            "name: \(name)"
        )
    }

    @Test(arguments: [
        "PATH",
        "PWD",
        "PUBLIC_KEY",
        "PASSWORD_FILE",
        "TOKEN_ENDPOINT",
        "AUTH_METHOD",
        "AWS_ACCESS_KEY_ID",
        "DATABASE_URL",
    ])
    func secretMetadataNamesStayVisible(name: String) {
        #expect(
            !EnvironmentSecretDetector.isPotentialSecret(name: name, value: "example-value"),
            "name: \(name)"
        )
    }

    @Test(arguments: [
        "postgres://user:password@example.test/database",
        "Server=example.test;Password=example-value",
        "https://example.test/hook?sig=example-value",
        "-----BEGIN PRIVATE KEY-----\nexample\n-----END PRIVATE KEY-----",
        "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJleGFtcGxlIn0.c2lnbmF0dXJl",
        "github_pat_examplevalue",
    ])
    func structuredSecretValuesAreDetectedWithNeutralNames(value: String) {
        #expect(
            EnvironmentSecretDetector.isPotentialSecret(name: "CONFIG", value: value),
            "value: \(value)"
        )
    }

    @Test
    func emptyValuesAreNotMasked() {
        #expect(!EnvironmentSecretDetector.isPotentialSecret(name: "TOKEN", value: ""))
        #expect(!EnvironmentSecretDetector.isPotentialSecret(name: "PASSWORD", value: "  "))
    }
}
