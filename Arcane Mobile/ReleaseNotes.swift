import SwiftUI

struct ReleaseNote: Identifiable, Hashable {
    let version: String
    let items: [Item]

    var id: String { version }

    struct Item: Identifiable, Hashable {
        let symbol: String
        let color: Color
        let title: String
        let body: String
        var id: String { title }
    }
}

/// Hardcoded changelog. When bumping `MARKETING_VERSION` in the project, prepend
/// a new entry whose `version` matches — auto-show keys off that string.
enum ReleaseNotes {
    static let all: [ReleaseNote] = [
        ReleaseNote(
            version: "0.1.0",
            items: [
                .init(
                    symbol: "rectangle.bottomthird.inset.filled",
                    color: .blue,
                    title: "Customizable Tab Bar",
                    body: "Long-press any tab in the bottom bar to swap it with a destination from Settings. Pin your most-used screens — like Volumes, Networks, or Users — for one-tap access."
                ),
                .init(
                    symbol: "pin.fill",
                    color: .orange,
                    title: "Pin Your Favorites",
                    body: "Pin containers, projects, and resources to keep them at the top of every list."
                ),
                .init(
                    symbol: "archivebox.fill",
                    color: .indigo,
                    title: "Archived Projects",
                    body: "Stopped projects collapse into an Archived section so your active work stays front and center."
                ),
            ]
        ),
    ]

    static var latest: ReleaseNote? { all.first }
}
