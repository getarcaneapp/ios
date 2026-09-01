import Arcane
import Foundation
import Testing

@testable import Arcane_Mobile

@Suite
struct SupportBundleBuilderTests {
    @Test
    func reportContainsActionableDiagnosticsAndRedactsSecrets() throws {
        let rawURL = try #require(
            URL(string: "https://admin:server-password@private.example.test:8443/arcane?token=url-secret")
        )
        let server = SupportBundleBuilder.serverDescriptor(
            for: rawURL,
            fingerprintSalt: "device-only-salt"
        )
        let report = SupportBundleBuilder.makeReport(
            from: snapshot(
                server: server,
                apiHealth: .init(
                    status: .unavailable,
                    detail: "HTTP_502: upstream failed; Authorization: Bearer auth-secret"
                ),
                activities: [failedActivity]
            )
        )

        #expect(report.text.contains("Address: https://private.example.test:8443/arcane"))
        #expect(report.text.contains("Stable server ID: srv-"))
        #expect(report.text.contains("API health detail: HTTP_502: upstream failed"))
        #expect(report.text.contains("Name: Production Docker"))
        #expect(report.text.contains("Docker server version: 27.5.1"))
        #expect(report.text.contains("Resource name: api"))
        #expect(report.text.contains("Error: pull failed"))
        #expect(report.text.contains("registry returned 401"))
        #expect(report.text.contains("ghcr.io/acme/api:latest"))
        #expect(report.text.contains("\"exitCode\":1"))
        #expect(report.text.contains("[REDACTED]"))
        #expect(!report.text.contains("[Excluded]"))
        #expect(!report.text.contains("server-password"))
        #expect(!report.text.contains("url-secret"))
        #expect(!report.text.contains("auth-secret"))
        #expect(!report.text.contains("metadata-secret"))
        #expect(!report.text.contains("payload-secret"))
        #expect(!report.text.contains(rawURL.absoluteString))
    }

    @Test
    func stableServerIdentityIgnoresCredentialsAndChangesAcrossDevices() throws {
        let firstURL = try #require(URL(string: "https://one:secret@arcane.example.test/base?token=one"))
        let secondURL = try #require(URL(string: "https://two:other@arcane.example.test/base?token=two"))
        let first = SupportBundleBuilder.serverDescriptor(for: firstURL, fingerprintSalt: "device-a")
        let repeated = SupportBundleBuilder.serverDescriptor(for: secondURL, fingerprintSalt: "device-a")
        let otherDevice = SupportBundleBuilder.serverDescriptor(for: firstURL, fingerprintSalt: "device-b")

        #expect(first.privateID == repeated.privateID)
        #expect(first.privateID != otherDevice.privateID)
        #expect(first.address == "https://arcane.example.test/base")
        #expect(first.transport == .https)
        #expect(first.hostKind == .hostname)
        #expect(first.usesBasePath)
        #expect(!first.usesNonDefaultPort)
    }

    @Test
    func reportBoundsRecentFailuresAndRejectsUnsafeVersionText() {
        let activities = (0..<12).map { index in
            activity(id: "failure_\(index)", resourceName: "service-\(index)")
        }
        let report = SupportBundleBuilder.makeReport(
            from: snapshot(
                server: nil,
                backendVersion: "https://private.example.test/version",
                activities: activities
            )
        )

        #expect(report.text.contains("Arcane version: Unavailable"))
        #expect(report.text.contains("Count included: 10"))
        #expect(report.text.contains("ID: failure_9"))
        #expect(!report.text.contains("ID: failure_10"))
        #expect(!report.text.contains("private.example.test/version"))
        #expect(report.filename == "Arcane-Mobile-Support-20260831-170000Z.txt")
    }

    @Test
    func redactorKeepsDebugContextWhileRemovingCredentialValues() {
        let input = "POST https://admin:pw@arcane.test/api?token=query-secret returned 401; "
            + "api_key=key-secret Authorization: Bearer bearer-secret request=abc123"
        let output = SupportBundleBuilder.redacted(input)

        #expect(output.contains("POST https://arcane.test/api?token=[REDACTED]"))
        #expect(output.contains("returned 401"))
        #expect(output.contains("request=abc123"))
        #expect(!output.contains("query-secret"))
        #expect(!output.contains("key-secret"))
        #expect(!output.contains("bearer-secret"))
        #expect(!output.contains("admin:pw"))
    }

    private var failedActivity: SupportBundleActivitySummary {
        SupportBundleActivitySummary(
            id: "activity_01J9FAIL",
            batchID: "batch_01J9",
            environmentID: "env-prod",
            environmentName: "Production Docker",
            type: "image_pull",
            status: "failed",
            resourceType: "container",
            resourceID: "container-api",
            resourceName: "api",
            progress: 78,
            step: "Pull image",
            latestMessage: "registry returned 401; token=activity-secret",
            error: "pull failed",
            startedBy: "operator",
            startedAt: Date(timeIntervalSince1970: 1_788_195_000),
            endedAt: Date(timeIntervalSince1970: 1_788_195_060),
            durationMs: 60_000,
            metadata: [
                "image": .string("ghcr.io/acme/api:latest"),
                "accessToken": .string("metadata-secret")
            ],
            detailError: nil,
            messages: [
                SupportBundleActivityMessageSummary(
                    createdAt: Date(timeIntervalSince1970: 1_788_195_030),
                    level: "error",
                    message: "registry returned 401; password=message-secret",
                    payload: [
                        "exitCode": .number(1),
                        "password": .string("payload-secret")
                    ]
                )
            ]
        )
    }

    private func activity(id: String, resourceName: String) -> SupportBundleActivitySummary {
        SupportBundleActivitySummary(
            id: id,
            batchID: nil,
            environmentID: "env-prod",
            environmentName: "Production Docker",
            type: "container_restart",
            status: "failed",
            resourceType: "container",
            resourceID: id,
            resourceName: resourceName,
            progress: nil,
            step: "Restart",
            latestMessage: "Failed",
            error: "Timeout",
            startedBy: "operator",
            startedAt: Date(timeIntervalSince1970: 1_788_195_000),
            endedAt: nil,
            durationMs: nil,
            metadata: nil,
            detailError: nil,
            messages: []
        )
    }

    private func snapshot(
        server: SupportBundleServerDescriptor?,
        backendVersion: String? = "2.7.1",
        apiHealth: SupportBundleCheckResult = .init(status: .passed, detail: "Reported status: UP"),
        activities: [SupportBundleActivitySummary]
    ) -> SupportBundleSnapshot {
        SupportBundleSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_788_195_600),
            appVersion: "0.8.2",
            appBuild: "82",
            operatingSystem: "iOS 26.0",
            deviceClass: "iPhone",
            localeIdentifier: "en_US",
            timeZoneIdentifier: "America/Chicago",
            authenticationState: .authenticated,
            userRole: .administrator,
            userID: "user-42",
            username: "operator",
            assignedRoles: ["admin"],
            backendMode: .rbac,
            server: server,
            serverURLConfigured: server != nil,
            clientConfigured: true,
            connectionWarning: "Proxy warning; api_key=warning-secret",
            activeEnvironmentID: "env-prod",
            activeEnvironmentName: "Production Docker",
            capabilitiesLoaded: true,
            supportsActivities: true,
            supportsRoleManagement: true,
            permissionsManifestLoaded: true,
            supportsExtendedMobileAPI: true,
            supportsMobilePush: true,
            diagnostics: SupportBundleDiagnostics(
                backend: SupportBundleBackendSummary(
                    version: backendVersion,
                    tag: "v2.7.1",
                    revision: "abcdef1",
                    goVersion: "go1.25.0",
                    buildTime: "2026-08-30T12:00:00Z",
                    enabledFeatures: ["activities", "rbac"],
                    updateAvailable: false,
                    newestVersion: nil
                ),
                apiHealth: apiHealth,
                versionEndpoint: .init(status: .passed, detail: nil),
                activeEnvironmentHealth: .init(status: .passed, detail: nil),
                dockerInfoCheck: .init(status: .passed, detail: nil),
                docker: SupportBundleDockerSummary(
                    serverVersion: "27.5.1",
                    apiVersion: "1.47",
                    goVersion: "go1.24.0",
                    operatingSystem: "Ubuntu 24.04",
                    os: "linux",
                    architecture: "arm64",
                    kernelVersion: "6.8.0",
                    driver: "overlay2",
                    cgroupDriver: "systemd",
                    cgroupVersion: "2",
                    cpuCount: 8,
                    memoryBytes: 17_179_869_184,
                    containers: 12,
                    containersRunning: 10,
                    containersPaused: 0,
                    containersStopped: 2,
                    images: 18,
                    dockerRootDirectory: "/var/lib/docker",
                    securityOptions: ["name=seccomp"]
                ),
                environmentInventory: .init(status: .passed, detail: "Returned 1 environment"),
                environments: [
                    SupportBundleEnvironmentSummary(
                        id: "env-prod",
                        name: "Production Docker",
                        apiAddress: "https://docker.internal:2376",
                        status: "online",
                        enabled: true,
                        isEdge: true,
                        connected: true,
                        edgeTransport: "grpc",
                        lastEdgeTransport: "grpc",
                        edgeSecurityMode: "mtls",
                        lastSeen: Date(timeIntervalSince1970: 1_788_195_500),
                        lastHeartbeat: Date(timeIntervalSince1970: 1_788_195_510),
                        lastPollAt: nil,
                        certificateCommonName: "arcane-agent-prod",
                        certificateExpiresAt: Date(timeIntervalSince1970: 1_820_000_000),
                        certificateDaysRemaining: 368,
                        certificateExpired: false,
                        certificateExpiringSoon: false
                    )
                ],
                activitySampling: .init(status: .passed, detail: "Returned recent failed activities"),
                failedActivities: activities
            )
        )
    }
}
