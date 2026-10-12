import Arcane
import SwiftUI
import Testing
import UIKit

@testable import Arcane_Mobile

@Suite("Environment update bubble presentation")
struct EnvironmentUpdateBubblePresentationTests {
    @Test
    func activeStatusesKeepTheirEnvironmentSymbol() {
        #expect(EnvironmentUpdateBubblePresentation(status: .pending) == .pending)
        #expect(EnvironmentUpdateBubblePresentation(status: .updating) == .updating)
        #expect(EnvironmentUpdateBubblePresentation.pending.terminalSymbol == nil)
        #expect(EnvironmentUpdateBubblePresentation.updating.terminalSymbol == nil)
    }

    @Test
    func successfulStatusesResolveToACheckmark() {
        for status in [
            EnvironmentUpdateResultStatus.updated,
            .upToDate,
            .triggered,
        ] {
            let presentation = EnvironmentUpdateBubblePresentation(status: status)
            #expect(presentation == .succeeded)
            #expect(presentation.terminalSymbol == "checkmark")
            #expect(presentation.isTerminal)
        }
    }

    @Test
    func unsuccessfulTerminalStatusesRemainDistinct() {
        #expect(EnvironmentUpdateBubblePresentation(status: .skippedOffline) == .skipped)
        #expect(EnvironmentUpdateBubblePresentation.skipped.terminalSymbol == "wifi.slash")
        #expect(EnvironmentUpdateBubblePresentation(status: .failed) == .failed)
        #expect(EnvironmentUpdateBubblePresentation.failed.terminalSymbol == "xmark")
        #expect(EnvironmentUpdateBubblePresentation(status: .unknown) == .unknown)
        #expect(EnvironmentUpdateBubblePresentation.unknown.terminalSymbol == "questionmark")
    }

    @MainActor
    @Test
    func mixedStatusCycleRendersAtPhoneWidth() throws {
        let results = [
            EnvironmentUpdateResult(
                environmentId: "1",
                environmentName: "Production",
                status: .updated
            ),
            EnvironmentUpdateResult(
                environmentId: "2",
                environmentName: "Staging",
                status: .upToDate
            ),
            EnvironmentUpdateResult(
                environmentId: "3",
                environmentName: "Development",
                status: .updating
            ),
            EnvironmentUpdateResult(
                environmentId: "4",
                environmentName: "Offline",
                status: .skippedOffline
            ),
            EnvironmentUpdateResult(
                environmentId: "5",
                environmentName: "Failed",
                status: .failed
            ),
            EnvironmentUpdateResult(
                environmentId: "0",
                environmentName: "Manager",
                status: .pending
            ),
        ]
        let ringEnvironments = results.enumerated().map { index, result in
            EnvironmentUpdateRingEnvironment(
                result: result,
                slotIndex: index,
                totalCount: results.count
            )
        }
        let model = EnvironmentUpdateSceneModel(
            kind: .updating,
            title: "Updating environments",
            subtitle: "4 of 6 complete",
            progress: 4.0 / 6.0,
            completedCount: 4,
            totalCount: 6,
            activeEnvironment: results[2],
            ringEnvironments: ringEnvironments
        )
        let fixture = EnvironmentUpdateScene(model: model)
            .frame(width: 350, height: 360)
            .padding(20)
            .background(Color(uiColor: .systemBackground))
            .environment(\.colorScheme, .light)

        let renderer = ImageRenderer(content: fixture)
        renderer.scale = 3
        let image = try #require(renderer.uiImage)

        #expect(image.size == CGSize(width: 390, height: 400))
        Attachment.record(image, named: "environment-update-mixed-status-cycle", as: .png)
    }
}
