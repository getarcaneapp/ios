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

/// Hardcoded changelog. When bumping `MARKETING_VERSION` in BuildNumber.xcconfig, prepend
/// a new entry whose `version` matches — auto-show keys off that string.
enum ReleaseNotes {
    static let all: [ReleaseNote] = [
        ReleaseNote(
            version: "0.6.0",
            new: [
                .init("Global variable management with secret and environment scoping."),
                .init("Configurable activity start toasts for user or system activity.")
            ],
            changed: [
                .init("Floating profile and App Settings buttons in sidebar navigation."),
                .init("Swarm management is marked as coming soon."),
                .init("Activities is accessed from the dashboard instead of navigation menus."),
                .init("Grouped Activity Center summaries for related operations."),
                .init("Event severity summaries, server-side filters, and permission-aware deletion."),
                .init("Template search, source filtering, metadata, and remote downloads."),
                .init("Navigation visibility based on server-provided permissions."),
                .init("Updates opens directly to environment update cards."),
                .init("Activity progress toasts open Activity Center when tapped.")
            ],
            fixed: [
                .init("Network topology renders as an interactive network-to-container diagram."),
                .init("Dashboard activity and prune buttons render separately."),
                .init("System prune reports background activity progress correctly."),
                .init("Bottom overlays sit at the safe-area edge in sidebar navigation."),
                .init("Dashboard container totals include every container in every enabled environment."),
                .init("Port mappings replace invalid host addresses with the wildcard address."),
                .init("Activity toast selections stay aligned beside their setting."),
                .init("Activity toasts use compact text with live progress."),
                .init("Dashboard live charts update without interrupting scrolling."),
                .init("Image update actions support consumers resolved by name.")
            ]
        ),
        ReleaseNote(
            version: "0.5.4",
            changed: [
                .init("Version details moved below the Danger Zone in App Settings."),
                .init("Bounded terminal and event history during long-running sessions.")
            ],
            fixed: [
                .init("Assistant uses safe context limits."), .init("Assistant stays hidden on unsupported devices."),
                .init("Dashboard update counts stay in sync after image scans and tab changes."),
                .init("Reliable live activity updates across environments."),
                .init("Reliable sign-out when the server is unavailable."),
                .init("Reliable log and statistics reconnection after reopening views."),
                .init("Correct terminal output when text and control sequences span network frames."),
                .init("Isolated cached data for servers that share a hostname.")
            ]
        ),
        ReleaseNote(
            version: "0.5.3",
            new: [
                .init("Optional sidebar navigation mode.")
            ]
        ),
        ReleaseNote(
            version: "0.5.2",
            new: [
                .init("Redesigned Updates page with one-tap and per-container updates."),
                .init("Container updates show progress in the pill and Live Activities.")
            ],
            changed: [
                .init("Terminal-style redesign for the operation log.")
            ],
            fixed: [
                .init("Ports showing thousands separators (9,000 → 9000)."),
                .init("Needs Attention and the Updates tile counted updates differently.")
            ]
        ),
        ReleaseNote(
            version: "0.5.1",
            changed: [
                .init("Removed the incorrect Add Environment dialog from the dashboard.")
            ]
        ),
        ReleaseNote(
            version: "0.5.0",
            new: [
                .init("Update All is now available from the dashboard.")
            ],
            changed: [
                .init("Bulk actions for containers, images, and volumes."),
                .init("Logs now support timestamps, copy, share, and clear."),
                .init("Volume browsing now has breadcrumbs and path jumping."),
                .init("Events now update live with a pause control."),
                .init("Pinned containers and projects now show on the dashboard.")
            ],
            fixed: [
                .init("Dashboard pull-to-refresh now reconnects live streams and refreshes data.")
            ]
        ),
        ReleaseNote(
            version: "0.4.1",
            new: [
                .init("Live Activities: deploys, redeploys, pulls, and builds now show live progress in the Dynamic Island and on the Lock Screen when you leave the app."),
                .init("A floating progress pill tracks the running operation inside the app — tap it any time to reopen the full log."),
                .init("Deployments are now synced with the server: if the connection drops mid-operation, the app re-attaches and picks up where the server is, and Cancel stops the operation server-side too. (Arcane v2 servers)"),
                .init("Pulling an image from the Images tab now shows real download progress with the same pill and Live Activity treatment."),
                .init("One-tap setup for the Arcane Community Templates registry."),
                .init("Your profile picture now syncs from the server — custom avatars and Gravatar (when enabled) — on the Account page and in Settings."),
            ],
            changed: [
                .init("The deploy log sheet can now be swiped away mid-run — the operation keeps going behind the progress pill instead of locking you in."),
                .init("Sign out moved to the Account page, with a combined Sign Out / Sign Out & Change Server menu."),
                .init("Clear Cache moved to a Danger Zone at the bottom of App Settings."),
                .init("The templates button on Projects now opens the template browser directly; registry management moved behind its Settings button."),
                .init("Profile name and email are now read-only for SSO accounts — they're managed by your identity provider."),
                .init("The project Files section now pins only the compose file, .env, and compose override files, with a Browse Files row for everything else — so you can always add new files even when custom files exist."),
                .init("The project file browser now works more like the Files app: a + button for new files and folders, one flat file list, and folder item counts and file sizes on each row."),
            ],
            fixed: [
                .init("A deployment that failed on the server no longer shows as complete just because the progress stream ended cleanly — the outcome is now confirmed against the server."),
                .init("Fixed getting signed out when launching the app after an update — a widget refresh could invalidate the app's session at the worst moment."),
            ]
        ),
        ReleaseNote(
            version: "0.4.0",
            new: [
                .init("Home and Lock Screen widgets: Status (configurable, with refresh button), Environments, and Updates & Vulnerabilities."),
                .init("Siri & Shortcuts: open tabs, containers, and projects; restart containers; start/stop projects (with confirmation)."),
                .init("Environment cards show live CPU and memory sparklines with a rolling minute of history."),
                .init("New Needs Attention card on the dashboard — offline environments, vulnerabilities, stopped containers, updates, expiring keys, and failed activities in one place."),
                .init("Vulnerability summaries use a proportional severity bar instead of plain numbers."),
                .init("New Account page in Settings: edit your display name and email, and change your password."),
            ],
            changed: [
                .init("Tapping the current tab again returns to its root page, like the native tab bar."),
                .init("System Prune options start from your server's configured prune defaults."),
                .init("Updater actions now live in the floating tab bar instead of a separate button row."),
                .init("Environment card stats survive scrolling and use fewer connections."),
                .init("Container Stats matches the app's card styling and loads with skeletons."),
                .init("Empty screens now explain themselves and offer a create action."),
                .init("Slimmer accent color picker."),
                .init("Smarter caching: fewer refetches on tab switches, and the disk cache cleans itself up."),
            ],
            fixed: [
                .init("Log tailing no longer drops frames on busy containers."),
                .init("Container Stats uses much less CPU and battery."),
                .init("Slow DNS no longer freezes the UI during server setup."),
                .init("Signing in no longer interrupts live dashboard streams."),
                .init("Icons load in parallel again in long lists."),
                .init("Inspect view search no longer lags on large containers."),
                .init("Confirmation dialog buttons no longer balloon with long titles."),
                .init("Delete dialogs opened from a detail page's bottom bar render full-width instead of squeezed."),
                .init("Signing in to a URL that serves a webpage (proxy portal, wrong port) now explains the problem instead of showing a raw JSON error."),
                .init("Destructive menu actions now show a red icon to match their red text."),
                .init("Cleaned up overlapping buttons in the log viewer's top bar."),
            ]
        ),
        ReleaseNote(
            version: "0.3.2",
            changed: [
                .init("Cleaned up alot of areas of the UI to more consistient with native iOS styling"),
            ]
        ),
        ReleaseNote(
            version: "0.3.1",
            new: [
                .init("Add New Application Icon Variants"),
                .init("Browse and edit custom project files from project details with a Files-style browser."),
            ],
            fixed: [
                .init("Delete confirmation dialogs now stay clear of the floating bottom bar so action buttons remain tappable."),
                .init("Activity Center live updates now reconnect after transient stream drops instead of immediately showing a paused warning."),
            ]
        ),
        ReleaseNote(
            version: "0.3.0",
            new: [
                .init("App Now Supports iOS 18 and up."),
                .init("Custom Navbar that morphs into resource controls in detail views."),
                .init("New Uniform Delete confirmation dialog for all actions."),
                .init("New Toasts for notifying you of completed or failed actions."),
                .init("Alpha version of Arcane Assistant for helping troubleshoot containers and more."),
            ],
            changed: [
                .init("Redesigned List View Rows to better visual appearance."),
                .init("Remove the Builds tab from resources since builds are not in the application yet."),
                .init("Redesigned the Image Details view with less clutter and proper update status display."),
                .init("Container Health Status displays in the list view."),
                .init("Overhaul of the project details page."),
                .init("Redesigned Navbar Tab Switcher on iOS 26."),
            ],
            fixed: [
                .init("Fixed the issue with the iOS Keychain signing users out even when refresh tokens exist."),
            ]
        ),
        ReleaseNote(
            version: "0.2.2",
            new: [
                .init("Activity Center for Arcane 2.0 shows live and recent work across all environments."),
                .init("Dashboard now has an Activity Center toolbar button and highlights recent failures."),
                .init("System prune controls now use Arcane's granular prune modes."),
            ],
            changed: [
                .init("Updated Status badge design."),
                .init("Server switching moved into App Settings."),
                .init("Application version details moved out of About."),
                .init("Dashboard totals now include polling and standby environments."),
                .init("RBAC-capable servers now use role pickers in user forms."),
                .init("Forms now use clearer labels, examples, helper text, and picker controls."),
                .init("App Settings now separates About links from support actions.")
            ],
            fixed: [
                .init("Updated libarcane-swift to decode null JSON object values correctly."),
                .init("App Settings cache size now reports persistent disk cache only."),
                .init("Dashboard keeps the selected environment at the top of the Environments list."),
                .init("Dashboard resource gauges now show live stats connection errors."),
                .init("Real devices now handle local-network Arcane server connections more reliably.")
            ]
        ),
        ReleaseNote(
            version: "0.2.1",
            changed: [
                .init("Server addresses entered without http:// or https:// now default to https://, and the login screen reminds you to include http:// when connecting to a local server."),
            ],
            fixed: [
                .init("You can now sign in to a local, HTTP-only Arcane server on your network — for example http://192.168.1.50:3000. iOS was silently blocking these plain-HTTP connections, so login failed with a generic connection error."),
                .init("Connection problems on the login screen now explain what actually went wrong — can't reach the server, server not found, timed out, or a secure-connection issue — instead of showing a raw system message."),
                .init("The Dashboard's Containers and Images tiles showed '—' instead of counts on Arcane 2.0 servers. They now read live per-environment data — the same source the environment cards use — so they populate regardless of server version, and a genuine zero shows as '0' instead of a dash."),
            ]
        ),
        ReleaseNote(
            version: "0.2.0",
            new: [
                .init("First Public Testflight Release!"),
            ]
        ),
        ReleaseNote(
            version: "0.1.9",
            changed: [
                .init("Searching and filtering large resource lists (Containers, Images, Networks, Projects, Volumes) is snappier — results are now computed once when you stop typing or change the sort or filter, instead of re-sorting on every keystroke."),
                .init("The dashboard now appears as soon as your environment cards are ready instead of waiting on the cross-environment Volumes and Updates totals, which fill in their tiles a moment later."),
                .init("Resource icons stop loading the moment you scroll past them, so fast scrolling through long lists uses less CPU and data."),
                .init("Loading skeletons now use a single synchronized shimmer that stays contained to each placeholder — no glow bleed onto neighboring content — and honor the system Reduce Motion setting."),
                .init("Swarm management is temporarily a placeholder while the screen is reworked. The tab stays in the navigation; the cluster, services, and nodes screens will return in a future update."),
            ]
        ),
        ReleaseNote(
            version: "0.1.8",
            fixed: [
                .init("Project compose files and env file do not show up when requested."),
            ]
        ),
        ReleaseNote(
            version: "0.1.7",
            new: [
                .init("New Roles screen for Arcane 2.0 servers: browse built-in roles, create and edit custom roles, and pick permissions from a searchable, grouped picker. Pinnable as a bottom tab or reachable from Settings → Administration."),
                .init("New OIDC Role Mappings screen for Arcane 2.0 servers: map an SSO claim value to a role and an optional environment scope. Mappings declared via the OIDC_ROLE_MAPPINGS env var are shown read-only with a lock badge."),
                .init("New Edit Role Assignments screen on every user's detail page (Arcane 2.0 servers): see a user's assignments grouped by scope (Global, then per-environment), add new assignments with a role + scope picker, swipe to remove manual assignments. OIDC-sourced assignments are shown but can't be changed from the app."),
                .init("Tabs that only make sense on Arcane 2.0 (Roles, OIDC Role Mappings) are automatically hidden when you connect to an older server, and reappear when you connect to a 2.0 one."),
            ],
            changed: [
                .init("Updated to work with Arcane 2.0's new role-based access control while still supporting older servers transparently. Existing admin users keep admin access after the server upgrade (Arcane 2.0 backfills them into the built-in Admin role)."),
                .init("Creating or editing a user on Arcane 2.0 servers now manages the admin role through the new role-assignment endpoint behind the scenes. The Administrator toggle still works the same way; for finer control, use the new Edit Role Assignments screen on the user's detail page."),
            ],
            fixed: [
                .init("Permission picker now expands one resource group at a time instead of opening every group together."),
                .init("Permission picker search field is now the standard iOS search bar at the top of the screen instead of a custom field inside the form."),
            ]
        ),
        ReleaseNote(
            version: "0.1.6",
            changed: [
                .init("Removed the Apprise section from Notifications. Apprise support has been dropped in Arcane 2.0."),
                .init("Admin badge in the Users list is now a solid indigo capsule with white text — better contrast and a less alarming color than the previous orange-on-orange."),
                .init("Tapping a row in any resource list (Containers, Images, Networks, Volumes, Projects) — or an environment card on the Dashboard — now zooms into the detail view instead of pushing flat from the right."),
                .init("Resource lists now show shimmering skeleton rows on first load instead of a centered 'Loading…' spinner, and the Dashboard's first-load skeleton has the same subtle shimmer."),
                .init("Paginated lists (Images, Networks, Volumes, Projects) auto-load the next page as you scroll, with a skeleton row in place while the next page fetches, instead of requiring you to tap 'Load More'."),
                .init("Search results in long lists settle 200 ms after you stop typing instead of re-filtering on every keystroke."),
                .init("Resource lists animate row reflow when you change the sort order or apply a filter."),
                .init("Empty states for all five resource lists now offer a primary action — Create for Networks/Volumes/Projects, Pull Image for Images, Refresh for Containers — instead of a dead end."),
                .init("Container detail tabs (Overview, Stats, Logs) slide between sections instead of snapping."),
                .init("The status dot on a running container's detail screen pulses subtly so it's clear the container is live."),
                .init("Start, Stop, Restart, and Redeploy buttons cross-fade smoothly into the in-flight spinner while an action runs."),
                .init("Dashboard counts and the CPU/Memory/Disk gauges on environment cards now roll between values instead of popping."),
                .init("Dashboard, Container, Project, and Environment detail screens now use iOS 26's soft scroll-edge effect so the toolbar fades naturally into the scrolling content."),
                .init("Logs view: the Live/Paused button icon morphs between states, pausing shows a floating 'N new' pill at the bottom that resumes live tailing and jumps to the latest line, and new log lines fade in gently instead of popping."),
                .init("The Arcane logo on the login screen bounces in with a spring on appear instead of just popping into place."),
                .init("Tab swap hint banner fades out smoothly when dismissed or when you discover the long-press feature, instead of popping."),
                .init("Dashboard tiles and mini-metric cards now read out as a single VoiceOver element with the metric name and value combined, instead of as a stack of separate icons and numbers."),
                .init("Action toolbar button labels now scale with the system Text Size setting."),
                .init("All new motion respects the system Reduce Motion accessibility setting."),
            ]
        ),
        ReleaseNote(
            version: "0.1.5",
            new: [
                .init("Redesigned login screen with a refined hero, glass-effect form card, and a persistent 'Try the demo' card that's always available — no need to wipe your server config to spin up a demo."),
            ],
            changed: [
                .init("Login screen and demo banner now use your selected accent color from Settings."),
                .init("Starting a demo now hides the rest of the login form so the spinner is the focus."),
                .init("Removed the redundant Cancel button from the Change Server flow."),
                .init("Removed the 'Welcome back' subtitle on the login screen for a cleaner hero."),
            ],
            fixed: [
                .init("'End' button in the demo banner now sends you back to the login screen immediately instead of waiting on background cleanup."),
                .init("Server URL, Username, and Password placeholders no longer pick up URL-style link coloring."),
                .init("'End' button color now matches your selected accent color instead of the system default."),
                .init("Appearance settings swatch selection is now derived from the stored accent color, so the checkmark always matches the actual color the app is using."),
                .init("Tab bar labels for long titles (Container Registries, Template Registries, Git Repositories, System Settings, Authentication) now use compact names so they no longer wrap or clip."),
            ]
        ),
        ReleaseNote(
            version: "0.1.4",
            fixed: [
                .init("Fix an issue where the ImageList logic was not parsed correctly"),
            ]
        ),
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
