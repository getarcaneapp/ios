# AGENTS.md

Guidance for AI agents (and new contributors) working on the Arcane Mobile iOS app — a native SwiftUI client for the [Arcane](https://github.com/getarcaneapp) Docker management platform.

## Golden rules

1. **Every user-facing change MUST be added to `Arcane Mobile/ReleaseNotes.swift`.** Bug fixes, new features, and behavior changes all get a bullet under the current `MARKETING_VERSION`'s entry — `new:` for features, `changed:` for behavior changes, `fixed:` for bug fixes. If no entry exists for the current version yet, prepend one (newest first, `version` must match `MARKETING_VERSION` exactly — the What's New auto-show keys off that string). Bullets are terse one-liners that just state the change — no explanations, no "now"/"same as X" comparisons, no em-dash elaborations (e.g. "Terminal-style redesign for the operation log.", not "The operation log got a terminal-style redesign — one dark console with live output for…").
2. **Never `git commit` or `git push`.** The user always commits and pushes themselves.
3. **Don't build via `xcodebuild` or run simulators (`simctl`) to verify changes.** The user builds and runs in Xcode.

## Project layout

```
ios/
├── Arcane Mobile.xcodeproj      # Xcode project (MARKETING_VERSION lives here)
├── Arcane-Mobile-Info.plist
├── AGENTS.md                    # This file
├── Arcane Mobile/               # Main app target
│   ├── Arcane_MobileApp.swift   # App entry point
│   ├── ContentView.swift        # Root view / tab scaffolding
│   ├── AppTab.swift             # Tab definitions
│   ├── ArcaneClientManager.swift# Auth + SDK client lifecycle
│   ├── Models.swift             # App-local shadow models (see "SDK" below)
│   ├── ReleaseNotes.swift       # Hardcoded changelog — UPDATE WITH EVERY CHANGE
│   ├── BuildNumber.xcconfig     # CURRENT_PROJECT_VERSION (build number)
│   ├── Extensions/              # Design system & helpers
│   │   ├── DesignTokens.swift   #   Radius.* corner-radius tokens
│   │   ├── Motion.swift         #   Motion.* animation tokens + PressableButtonStyle
│   │   ├── Animation+Motion.swift
│   │   ├── GlassCompat.swift    #   iOS 26 Liquid Glass compatibility shims
│   │   └── Color+Hex.swift, View+Debounce.swift, View+AIAssistant.swift
│   ├── Networking/              # Caching layer, token store, lenient decoding
│   ├── Services/                # Observable stores & app services
│   │   ├── AI/                  #   On-device AI assistant (Foundation Models)
│   │   ├── DashboardStreamStore.swift, ActivityCenterStore.swift, ...
│   │   └── DeployLiveActivityController.swift (Live Activities)
│   ├── Intents/                 # App Intents (Siri / Shortcuts)
│   ├── Types/, Utils/           # Misc shared types & helpers
│   └── Views/                   # SwiftUI views, grouped by domain
│       ├── Main/, Common/, Components/
│       ├── Containers/, Projects/, Images/, Volumes/, Networks/
│       ├── Environments/, Events/, Jobs/, Ports/, Swarm/, Updates/
│       ├── Auth/, Settings/, Customize/, BackendResources/
│       ├── AIAssistant/, Activities/
│       └── WhatsNew/            # Renders ReleaseNotes.swift
├── ArcaneWidgets/               # Widget extension target (widgets, Live Activities)
├── Shared/                      # Code shared between app and widget targets
│   ├── AppGroup.swift, SharedKeychain.swift
│   └── WidgetSnapshot*.swift, DeployActivityAttributes.swift
└── build/                       # Build artifacts (ignore)
```

## Architecture & conventions

### SDK and networking
- The Arcane API client is **libarcane-swift**, a remote SPM dependency pinned to a branch. Editing a local copy of the SDK does nothing — the app resolves it from GitHub.
- Most domains use the SDK's typed services, including **image updates** (`client.images.updateSummary/checkUpdateByRef/checkAllUpdates/updateInfoByRefs` + the SDK's `ImageUpdateInfo.asUpdateResponse` bridge). Exception: **vulnerabilities** still use app-local types in `Models.swift` + raw REST (SDK shapes mismatch the server). Settings saves send a raw `[String: String]` dict, not the SDK's `UpdateSettings`.
- When a change needs new SDK surface, make the change in `../libarcane-swift` (never commit/tag/push it — the user handles that) and remember the app resolves the SDK from GitHub: local SDK edits don't build into the app until pushed and the package is re-resolved.
- The app must support **both Arcane v1 and v2 backends** (v2 has breaking API changes, e.g. no `/dashboard/environments`). Gate v2-only features on capability checks (e.g. `supportsActivities`).
- Auth uses single-use refresh-token rotation and the session is shared with widgets via the shared keychain — be careful around `AuthManager` refresh/401 logic; see the reload-before-refresh invariant there.

### Concurrency
- The app target builds with **main-actor-by-default isolation** (Xcode 26). Types are implicitly `@MainActor`; use SDK-native/`nonisolated` types for off-actor work.

### UI / design system
- Use central design tokens, never raw literals:
  - Corner radii: `Radius.*` (always `.continuous`).
  - Animation: `Motion.*` tokens; `PressableButtonStyle` for buttons (never on list rows).
- Effects are restrained and contained — no bright or additive glows.
- Transient feedback uses the toast system: `showToast(.success/.error/.copied/.info)` — not `.alert`.
- iOS 26 Liquid Glass: `.glassEffect` caches and won't shrink — animate via scale+opacity, not frame resizes; don't toggle glass on interpolated values.
- **SwiftUI gotcha:** `Text("\(someInt)")` locale-formats integers (9000 → "9,000"). Use `Text(verbatim:)` or `String()` for IDs, ports, counts that must render literally.

### AI assistant
- On-device assistant (Apple Foundation Models) lives in `Services/AI` + `Views/AIAssistant`. It has a **hard 4096-token context window** — keep tools to ~16 max; extend existing topic enums instead of adding tools.

### Versioning
- `MARKETING_VERSION` (e.g. `0.5.1`) is set in the Xcode project build settings; `BuildNumber.xcconfig` holds `CURRENT_PROJECT_VERSION`. Release-note entries key off `MARKETING_VERSION`.

## Workflow checklist for any change

1. Make the code change following the conventions above.
2. Add a bullet to `ReleaseNotes.swift` under the current version (create the entry if missing).
3. Do **not** build/run to verify — the user does that in Xcode.
4. Do **not** commit — the user handles git.
