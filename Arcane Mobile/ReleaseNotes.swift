import SwiftUI

struct ReleaseNote: Identifiable, Hashable {
    let version: String
    let new: [Bullet]
    let changed: [Bullet]
    let fixed: [Bullet]

    var id: String { version }

    init(
        version: String,
        new: [Bullet] = [],
        changed: [Bullet] = [],
        fixed: [Bullet] = []
    ) {
        self.version = version
        self.new = new
        self.changed = changed
        self.fixed = fixed
    }

    struct Bullet: Hashable {
        let text: String
        let badge: Badge?

        init(_ text: String, badge: Badge? = nil) {
            self.text = text
            self.badge = badge
        }
    }

    enum Badge: Hashable {
        case premium

        var label: String {
            switch self {
            case .premium: return "Premium"
            }
        }

        var color: Color {
            switch self {
            case .premium: return .purple
            }
        }
    }
}

/// Hardcoded changelog. When bumping `MARKETING_VERSION` in the project, prepend
/// a new entry whose `version` matches — auto-show keys off that string.
enum ReleaseNotes {
    static let all: [ReleaseNote] = [
        ReleaseNote(
            version: "0.1.1",
            changed: [
                .init("Overall Design fixes between iOS 18 and iOS 26"),
            ],
            fixed: [
                .init("Fixed a security issue where crafted icon URLs could leak authentication headers to external servers."),
            ]
        ),
        ReleaseNote(
            version: "0.1.0",
            new: [
                .init("Initial Arcane Mobile Beta release"),
                .init("Customizable bottom tab bar — long-press any tab to swap"),
                .init("Pin containers, projects, and resources to keep them at the top"),
                .init("Archived projects collapse into their own section"),
                .init("Redesigned Updater Status and Updater History screens"),
                .init("Redesigned Events list with severity filtering"),
                .init("Ports grouped by container"),
                .init("Show More pagination on Events and Updater History"),
                .init("Reset to defaults from the tab customization sheet"),
            ],
            changed: [
                .init("Reorganized navigation to match the web app (Management / Resources / Swarm / Administration)"),
                .init("Tab customization sheet now uses a tile grid and opens to full height"),
                .init("Smoother scrolling on the dashboard, container stats, and tab picker"),
                .init("Removed OIDC sign-in from the login screen"),
                .init("Removed Build Workspace (build settings still available to admins)"),
            ],
            fixed: [
                .init("Container and project icons no longer crop wider artwork"),
                .init("Events sort newest-first"),
                .init("GitOps icon now renders"),
                .init("Reduced memory use on long image lists"),
            ]
        ),
    ]

    static var latest: ReleaseNote? { all.first }
}
