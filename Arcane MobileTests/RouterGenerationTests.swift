import Testing

@testable import Arcane_Mobile

@MainActor
@Suite("Route completion identity")
struct RouterGenerationTests {
    @Test
    func clearingAConsumedRouteKeepsItsCompletionIdentity() {
        let router = QuickActionRouter()
        router.pendingRoute = .container(environmentID: "one", id: "container")
        let generation = router.routeGeneration
        router.pendingRoute = nil
        #expect(router.routeGeneration == generation)
        router.pendingRoute = nil
        #expect(router.routeGeneration == generation)
    }

    @Test
    func newerConsumedDestinationRetiresAnOlderResourceCompletion() {
        for destination: QuickActionRouter.PendingRoute in [
            .project(environmentID: "one", id: "project"),
            .tab(AppTab.dashboard.id),
        ] {
            let router = QuickActionRouter()
            router.pendingRoute = .container(environmentID: "one", id: "container")
            let delayedContainerGeneration = router.routeGeneration
            router.pendingRoute = nil
            router.pendingRoute = destination
            let newerGeneration = router.routeGeneration
            router.pendingRoute = nil
            #expect(router.pendingRoute == nil)
            #expect(router.routeGeneration == newerGeneration)
            #expect(router.routeGeneration != delayedContainerGeneration)
        }
    }

    @Test
    func repeatingTheSameDestinationCreatesANewCompletionIdentity() {
        let router = QuickActionRouter()
        let destination = QuickActionRouter.PendingRoute.project(environmentID: "one", id: "project")
        router.pendingRoute = destination
        let firstGeneration = router.routeGeneration
        router.pendingRoute = destination
        #expect(router.routeGeneration != firstGeneration)
    }
}
