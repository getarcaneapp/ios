import Testing

@testable import Arcane_Mobile

@Suite
struct DashboardVersionBadgeFormatterTests {
    @Test
    func arcaneVersionUsesBestAvailableValue() {
        #expect(
            DashboardVersionBadgeFormatter.arcane(
                displayVersion: "2.8.0",
                currentTag: "v2.7.0",
                currentVersion: "2.6.0"
            ) == "v2.8.0"
        )
        #expect(
            DashboardVersionBadgeFormatter.arcane(
                displayVersion: "",
                currentTag: "v2.7.0",
                currentVersion: "2.6.0"
            ) == "v2.7.0"
        )
        #expect(
            DashboardVersionBadgeFormatter.arcane(
                displayVersion: "",
                currentTag: nil,
                currentVersion: "2.6.0"
            ) == "v2.6.0"
        )
        #expect(
            DashboardVersionBadgeFormatter.arcane(
                displayVersion: "",
                currentTag: nil,
                currentVersion: ""
            ) == "—"
        )
    }

    @Test
    func dockerAPIVersionHandlesMissingAndWhitespaceValues() {
        #expect(DashboardVersionBadgeFormatter.dockerAPI("1.49") == "1.49")
        #expect(DashboardVersionBadgeFormatter.dockerAPI(" 1.48 ") == "1.48")
        #expect(DashboardVersionBadgeFormatter.dockerAPI(" ") == "—")
        #expect(DashboardVersionBadgeFormatter.dockerAPI(nil) == "—")
    }
}
