import Arcane
import Foundation
import Testing

@testable import Arcane_Mobile

@Suite("Resource routing")
@MainActor
struct ResourceRoutingTests {
    @Test
    func widgetDestinationsRemainPendingUntilTheAuthenticatedRootConsumesThem() throws {
        let router = QuickActionRouter()
        #expect(
            router.handle(
                url: try #require(
                    URL(string: "arcane-mobile://open?tab=containers&env=remote&container=not-in-first-page"))))
        #expect(router.pendingRoute == .container(environmentID: "remote", id: "not-in-first-page"))
        #expect(router.pendingTabID == nil)
        #expect(router.pendingRoute?.environmentID == "remote")

        #expect(
            router.handle(
                url: try #require(URL(string: "arcane-mobile://open?tab=projects&env=remote&project=archived-project")))
        )
        #expect(router.pendingRoute == .project(environmentID: "remote", id: "archived-project"))
        #expect(router.pendingTabID == nil)
    }

    @Test
    func legacyTabLinksRetainEnvironmentAndUnknownURLsLeaveTheRouteIntact() throws {
        let router = QuickActionRouter()
        #expect(router.handle(url: try #require(URL(string: "arcane-mobile://open?tab=projects&env=second"))))
        #expect(router.pendingRoute == .tab(AppTab.projects.id, environmentID: "second"))
        #expect(!router.handle(url: try #require(URL(string: "https://example.com/open"))))
        #expect(router.pendingRoute == .tab(AppTab.projects.id, environmentID: "second"))
    }

    @Test
    func pushesUseTheSameTypedContainerDestination() {
        let router = QuickActionRouter()
        router.handle(route: MobilePushRoute(kind: .container, environmentId: "env", id: "container"))
        #expect(router.pendingRoute == .container(environmentID: "env", id: "container"))
    }

    @Test
    func inspectedDestinationPreservesImageLabelsAndStructuredMounts() {
        let mounts = [
            ContainerMount(type: "bind", source: "/srv/data:with-colon", destination: "/data", rw: false),
            ContainerMount(type: "volume", name: "cache", destination: "/cache", driver: "local", rw: true),
        ]
        let details = ContainerDetails(
            id: "not-in-first-page",
            name: "/api",
            image: "registry.example/api:v2",
            imageId: "sha256:image",
            created: "2026-09-29T12:00:00Z",
            state: ContainerState(status: "running", running: true),
            mounts: mounts,
            labels: ["com.example.team": "operations"]
        )
        let summary = details.navigationSummary
        #expect(summary.id == details.id)
        #expect(summary.displayName == "api")
        #expect(summary.image == details.image)
        #expect(summary.labels == details.labels)
        #expect(summary.mounts == mounts)
        #expect(summary.created > 0)
    }
}
