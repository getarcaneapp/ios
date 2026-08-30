import Testing

@testable import Arcane_Mobile

@Suite("Project row navigation selection")
struct ProjectRowSelectionTests {
    @Test
    func returningFromTheSelectedProjectClearsItsRow() {
        #expect(ProjectsView.selectionAfterReturning("project-a", from: "project-a") == nil)
    }

    @Test
    func returningFromAnotherProjectPreservesTheCurrentSelection() {
        #expect(
            ProjectsView.selectionAfterReturning("project-b", from: "project-a")
                == "project-b"
        )
        #expect(ProjectsView.selectionAfterReturning(nil, from: "project-a") == nil)
    }
}
