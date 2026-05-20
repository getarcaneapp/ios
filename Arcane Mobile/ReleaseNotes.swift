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
            version: "0.1.3",
            new: [
                .init("New cross-environment Updates screen: per-environment summary cards with totals, per-image update rows, and a 'Recheck all images' action for each environment."),
            ],
            changed: [
                .init("Refactored the app to use the shared Arcane Swift SDK directly for API models and services, improving consistency with the backend."),
            ]
        ),
        ReleaseNote(
            version: "0.1.2",
            new: [
                .init("Dashboard now shows an Updates tile with the total count of pending image updates across all environments. Tap to jump into the Updates tab."),
                .init("New floating Liquid Glass action bar on Project, Container, Environment, and Updates detail screens — primary actions (Stop, Restart, Redeploy, etc.) live in circular glass buttons above the tab bar."),
            ],
            changed: [
                .init("Dashboard now loads environment cards lazily as you scroll and shows at most 50 environments at a time, with a link to view the full list."),
                .init("Replaced the Environments overview tile with the new Updates tile — the per-environment cards below already convey online/total counts."),
                .init("Container detail tabs are now Overview, Stats, and Logs (replacing the Inspect tab). Inspect moved to a toolbar button; Terminal also lives in the toolbar when the container is running."),
            ],
            fixed: [
                .init("Error messages now show human-readable text instead of raw API responses or schema URLs"),
                .init("Error banners wrap to multiple lines so long messages are fully readable"),
                .init("Validation errors point to the specific field that needs attention"),
                .init("Fixed a security issue where a malicious or compromised server could degrade or crash the app by returning an excessive number of environments."),
                .init("Fixed a security issue where a malicious or compromised server could crash the app at launch by returning duplicate keys in the public OIDC settings response."),
            ]
        ),
        ReleaseNote(
            version: "0.1.1",
            new: [
                .init("Redesigned dashboard with per-environment summary cards showing live CPU, memory, disk, and container/image counts"),
                .init("Long-press an environment card to set it as the active context or jump into system details"),
                .init("Volume totals now aggregate across all environments on the dashboard"),
                .init("Skeleton loading state on first dashboard load"),
            ],
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
