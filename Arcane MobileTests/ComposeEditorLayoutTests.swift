import SwiftUI
import Testing
import UIKit
@testable import Arcane_Mobile

@Suite("Compose editor layouts")
@MainActor
struct ComposeEditorLayoutTests {
    @Test(arguments: [CGSize(width: 375, height: 667), CGSize(width: 1024, height: 1366)])
    func composeFitsDevice(_ size: CGSize) throws {
        let source = "services:\n  web:\n    image: nginx:alpine\n    ports:\n      - \"8080:80\"\n  database:\n    image: postgres:17\nvolumes:\n  data: {}\n"
        let host = UIHostingController(rootView: NavigationStack {
            ComposePreviewEditor(text: .constant(source))
                .navigationTitle("compose.yaml")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    AppToolbarItem(placement: .topBarTrailing) {
                        Button("Save", systemImage: "checkmark") {}.labelStyle(.iconOnly)
                    }
                    if #available(iOS 26, *) {
                        ToolbarSpacer(.fixed, placement: .topBarTrailing)
                    }
                }
        }.environment(\.horizontalSizeClass, size.width > 500 ? .regular : .compact))
        try render(host, size: size, name: "compose-\(Int(size.width))")
    }

    @Test func environmentWithLargeText() throws {
        let host = UIHostingController(rootView: NavigationStack {
            EnvPreviewEditor(text: .constant("# preserved\nDATABASE_PASSWORD=example\nPORT=8080\n"))
        }.environment(\.dynamicTypeSize, .accessibility3))
        try render(host, size: CGSize(width: 375, height: 667), name: "environment-large-text")
    }

    @Test(arguments: [CGSize(width: 375, height: 667), CGSize(width: 1024, height: 1366)])
    func arcaneServiceFieldsFitDevice(_ size: CGSize) throws {
        let host = UIHostingController(rootView: NavigationStack {
            ComposeServiceForm(text: .constant(ComposeScreenshotFixture.source), service: "arcane", readOnly: false)
        }.environment(\.horizontalSizeClass, size.width > 500 ? .regular : .compact))
        try render(host, size: size, name: "arcane-service-\(Int(size.width))")
    }

    @Test func healthcheckAndStaticNetworksRender() throws {
        let source = ComposeScreenshotFixture.source
        let health = UIHostingController(rootView: NavigationStack {
            ComposeHealthcheckForm(text: .constant(source), path: ["services", "arcane", "healthcheck"], readOnly: false)
        })
        try render(health, size: CGSize(width: 375, height: 667), name: "arcane-healthcheck")
        let network = UIHostingController(rootView: NavigationStack {
            ComposeNetworkAttachmentsForm(text: .constant(source), path: ["services", "arcane", "networks"], readOnly: false)
        })
        try render(network, size: CGSize(width: 375, height: 667), name: "arcane-network")
    }

    @Test func serviceOverviewWithAccessibleTextAndDarkAppearance() throws {
        let host = UIHostingController(rootView: NavigationStack {
            ComposeServiceForm(text: .constant(ComposeScreenshotFixture.source), service: "arcane", readOnly: false)
        }.environment(\.dynamicTypeSize, .accessibility2).environment(\.colorScheme, .dark))
        try render(host, size: CGSize(width: 375, height: 812), name: "service-overview-accessible-dark")
    }

    @Test func minimalServiceShowsOnlyExistingConfiguration() throws {
        let source = "services:\n  web:\n    image: nginx:alpine\n"
        let host = UIHostingController(rootView: NavigationStack {
            ComposeServiceForm(text: .constant(source), service: "web", readOnly: false)
        })
        try render(host, size: CGSize(width: 375, height: 667), name: "service-existing-only")
        #expect(try ComposeDocument(source).nativeFields(at: [.key("services"), .key("web")]).map(\.name) == ["image"])
        let explicitEmpty = "services:\n  web:\n    ports: []\n    environment:\n"
        #expect(try ComposeDocument(explicitEmpty).nativeFields(at: [.key("services"), .key("web")]).map(\.name) == ["ports", "environment"])
    }

    @Test func projectNetworkDetailsAndNestedFieldsRender() throws {
        let source = ComposeScreenshotFixture.source
        let resources = UIHostingController(rootView: NavigationStack {
            ComposeResourceDefinitionList(text: .constant(source), kind: "networks", readOnly: false)
        })
        try render(resources, size: CGSize(width: 375, height: 667), name: "project-networks")
        let details = UIHostingController(rootView: NavigationStack {
            ComposeResourceDefinitionForm(text: .constant(source), kind: "networks", name: "vlan25", readOnly: false)
        })
        try render(details, size: CGSize(width: 375, height: 667), name: "project-network-details")
        let nested = UIHostingController(rootView: NavigationStack {
            ComposeNativeFieldsForm(text: .constant(source), path: ["services", "arcane"], title: "Service settings", readOnly: false, excluding: ["build", "deploy"])
        }.environment(\.dynamicTypeSize, .accessibility2))
        try render(nested, size: CGSize(width: 375, height: 667), name: "native-fields-large-text")
    }

    private func render<V: View>(_ host: UIHostingController<V>, size: CGSize, name: String) throws {
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        #expect(host.view.bounds.width == size.width)
        #expect(host.view.bounds.height == size.height)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let data = try #require(image.pngData())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).png")
        try data.write(to: url)
        #expect(data.count > 1_000)
    }
}
