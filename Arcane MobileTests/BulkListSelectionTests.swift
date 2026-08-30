import SwiftUI
import Testing
import UIKit

@testable import Arcane_Mobile

@Suite("Bulk list selection")
struct BulkListSelectionTests {
    @MainActor
    @Test
    func navigationModeDoesNotExposeASelectionBinding() {
        let selection = Binding.constant(Set(["sonarr"]))

        #expect(BulkListSelection.binding(selection, isSelecting: false) == nil)
    }

    @MainActor
    @Test
    func selectionModeForwardsReadsAndWrites() throws {
        let storage = SelectionStorage(["sonarr"])
        let selection = Binding(
            get: { storage.value },
            set: { storage.value = $0 }
        )
        let activeSelection = try #require(
            BulkListSelection.binding(selection, isSelecting: true)
        )

        #expect(activeSelection.wrappedValue == ["sonarr"])
        activeSelection.wrappedValue.insert("radarr")
        #expect(storage.value == ["radarr", "sonarr"])
    }

    @MainActor
    @Test
    func taggedRowsOnlyRenderSelectedDuringBulkSelection() async throws {
        let navigationSelectionCount = try await renderedSelectionCount(isSelecting: false)
        let bulkSelectionCount = try await renderedSelectionCount(isSelecting: true)

        #expect(navigationSelectionCount == 0)
        #expect(bulkSelectionCount == 1)
    }

    @MainActor
    private func renderedSelectionCount(isSelecting: Bool) async throws -> Int {
        let host = UIHostingController(
            rootView: BulkListSelectionFixture(isSelecting: isSelecting)
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        host.view.layoutIfNeeded()

        return try #require(host.view.selectedRowCount)
    }
}

private struct BulkListSelectionFixture: View {
    let isSelecting: Bool
    @State private var selection = Set(["sonarr"])

    var body: some View {
        List(selection: BulkListSelection.binding($selection, isSelecting: isSelecting)) {
            Text("sonarr").tag("sonarr")
            Text("radarr").tag("radarr")
        }
        .environment(
            \.editMode,
            .constant(isSelecting ? EditMode.active : EditMode.inactive)
        )
    }
}

private extension UIView {
    var selectedRowCount: Int? {
        if let tableView = self as? UITableView {
            return tableView.indexPathsForSelectedRows?.count ?? 0
        }
        if let collectionView = self as? UICollectionView {
            return collectionView.indexPathsForSelectedItems?.count ?? 0
        }
        for subview in subviews {
            if let count = subview.selectedRowCount {
                return count
            }
        }
        return nil
    }
}

@MainActor
private final class SelectionStorage {
    var value: Set<String>

    init(_ value: Set<String>) {
        self.value = value
    }
}
