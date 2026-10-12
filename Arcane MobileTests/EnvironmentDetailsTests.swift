import Arcane
import SwiftUI
import Testing
import UIKit

@testable import Arcane_Mobile

@Suite("Environment details", .serialized)
struct EnvironmentDetailsTests {
    @Test func olderEnvironmentsDecodeWithoutTunnelMetrics() throws {
        let data = Data(
            #"{"id":"1","name":"Direct","apiUrl":"https://agent.example.test","status":"online","enabled":true,"isEdge":false}"#
                .utf8
        )
        let details = try ArcaneJSON.makeDecoder().decode(EnvironmentDetails.self, from: data)
        #expect(details.environment.id == "1")
        #expect(details.environment.isEdge == false)
        #expect(details.edgeDataPlane == nil)
        #expect(details.edgeRoundTripMs == nil)
        #expect(details.edgeOpenStreams == nil)
    }

    @Test func tunnelMetricsDecodeAlongsideTheSDKEnvironment() throws {
        let details = try fixture()
        #expect(details.environment.connected == true)
        #expect(details.environment.edgeSessionId == "example-session")
        #expect(details.edgeDataPlane == "mux")
        #expect(details.edgeRoundTripMs == 17.8)
        #expect(details.edgeOpenStreams == 3)
        #expect(details.environment.edgeMTLSCertificate?.commonName == "palladium-example")
    }

    @MainActor
    @Test(arguments: [(375.0, false), (375.0, true), (834.0, false), (1024.0, false)])
    func connectionLayoutsRenderAtPhoneAndTabletWidths(width: Double, largeText: Bool) throws {
        let details = try fixture()
        let size = CGSize(width: width, height: 1100)
        let host = UIHostingController(
            rootView: ScrollView {
                VStack(spacing: 16) {
                    ScrollableTabBar(
                        selection: .constant(EnvironmentDetailSection.connection),
                        options: EnvironmentDetailSection.allCases.map {
                            ScrollableTabOption($0, title: $0.rawValue, systemImage: $0.systemImage)
                        },
                        accessibilityLabel: "Environment detail sections"
                    )
                    EnvironmentConnectionView(
                        environment: details.environment,
                        details: details,
                        managerURL: "https://containers.example.test"
                    )
                }
                .padding(16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .environment(\.dynamicTypeSize, largeText ? .accessibility3 : .large)
            .environment(\.colorScheme, .dark)
        )
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.overrideUserInterfaceStyle = .dark
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let data = try #require(image.pngData())
        #expect(data.count > 1_000)
        Attachment.record(
            image,
            named: "environment-connection-\(Int(width))-\(largeText ? "accessible" : "standard")",
            as: .png
        )
    }

    private func fixture() throws -> EnvironmentDetails {
        let data = Data(
            """
            {"id":"1","name":"Palladium","apiUrl":"","status":"online","enabled":true,"isEdge":true,
            "connected":true,"edgeTransport":"grpc","edgeSecurityMode":"token","edgeSessionId":"example-session",
            "edgeDataPlane":"mux","edgeRoundTripMs":17.8,"edgeOpenStreams":3,
            "connectedAt":"\(ISO8601DateFormatter().string(from: Date(timeIntervalSinceNow: -420)))",
            "lastHeartbeat":"\(ISO8601DateFormatter().string(from: Date()))",
            "edgeMTLSCertificate":{"commonName":"palladium-example","expiresAt":"2031-07-14T17:35:00Z","daysRemaining":1737,"expired":false,"expiringSoon":false}}
            """.utf8
        )
        return try ArcaneJSON.makeDecoder().decode(EnvironmentDetails.self, from: data)
    }
}
