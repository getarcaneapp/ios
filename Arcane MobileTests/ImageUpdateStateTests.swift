import Foundation
import Testing
import Arcane
@testable import Arcane_Mobile

@Suite struct ImageUpdateStateTests {
    @Test func uncheckedInlineDataIsNotCurrent() {
        #expect(ImageUpdateState(info: nil) == .unknown)
        #expect(ImageUpdateState(info: .init()) == .unknown)
        #expect(ImageUpdateState(info: .init(checkTime: Date())) == .upToDate)
    }

    @Test func availableUpdateWinsAcrossTags() {
        let results: [String: ImageUpdateResponse] = [
            "app:one": .init(hasUpdate: false, currentVersion: "one"),
            "app:two": .init(hasUpdate: true)
        ]
        #expect(ImageUpdateState.resolve(inline: nil, references: ["app:one", "app:two"], results: results) == .hasUpdate)
        #expect(ImageUpdateState.resolve(inline: nil, references: ["app:two", "app:one"], results: results) == .hasUpdate)
    }

    @Test func failedAndMissingChecksAreNotCurrent() {
        let good = ImageUpdateResponse(currentVersion: "one")
        #expect(ImageUpdateState.resolve(inline: nil, references: ["app:one", "app:two"], results: ["app:one": good]) == .unknown)
        #expect(ImageUpdateState.resolve(inline: nil, references: ["app:one", "app:two"], results: ["app:one": good, "app:two": .init(error: "Registry unavailable")]) == .error("Registry unavailable"))
    }

    @Test func inlineAvailabilityAppearsBeforeExtraRequest() {
        #expect(ImageUpdateState.resolve(inline: .init(hasUpdate: true), references: ["app:latest"], results: [:]) == .hasUpdate)
        #expect(ImageUpdateState(info: .init(error: "Registry denied")) == .error("Registry denied"))
    }

    @Test func freshChecksReplaceOldInlineResult() {
        #expect(ImageUpdateState.resolve(inline: .init(hasUpdate: true), references: ["app:latest"], results: ["app:latest": .init(currentVersion: "latest")]) == .upToDate)
    }
}
