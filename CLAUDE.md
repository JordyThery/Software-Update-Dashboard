# Software Update Dashboard: instructions for Claude

At the start of every conversation, run ../JTKit/Scripts/check-versions.sh (or fetch it from GitHub if ../JTKit isn't there) and mention the result in one line if anything is out of date.

Shared code and the standards for every app: see JTKit's CLAUDE.md and ROADMAP.md (github.com/JordyThery/JTKit, or ../JTKit in the workspace). The plan for this app is docs/PLAN.md.

## What the app does

A read-only Mac app that answers, for the devices a Blueprint is scoped to, whether they are on the OS version its software update asks for, and if not, why not. The unit of work is a tracked Blueprint: a Blueprint with a software update; its devices are those of the Jamf Pro groups it is scoped to. Milestone 1: Jamf Pro through the Jamf Platform API, iOS, iPadOS and macOS.

## How to work on it

- App-only work: open `Software Update Dashboard.xcodeproj`. This folder's notes load and it builds against the published JTKit.
- Anything that changes JTKit: work in `~/Developer/Apps.xcworkspace`.
- Never have the app open in both at once.
- Build releases from the app's own project, so they use the published JTKit version.
- After merging into main, push main to origin straight away (keep GitHub in sync).
- Jordy is not a programmer: explain changes in plain language, in small steps.

## Architecture

- `App/`: the app (About, Check for Updates, Settings, Connection menu, activity log, Demo Mode), `UnderTest`.
- `Connections/`: `AppConnection` (a JTKit connection plus the Jamf Pro server's time zone), `ConnectionsModel` (saved connections, the one in use, demo mode, the read-only clients), the Connections tab.
- `State/`: the content caches (0.4: `CachesModel`, the sweeps of the connection in use with their trend; `ContentCaches.swift`: the app’s record of a sweep, `CacheSweepRecord`, and its folder, `CacheArchive`), tracked Blueprints (with the move from tracked groups), the history (which also saves `ReportedDeadlines`, Jamf’s deadlines the Blueprint’s devices reported), the dashboard model (reads and Inspects are run by the model, never tied to a view: `readFirstTime`, `readIfNeverRead`; only Stop, Stop Tracking or a switch of connection ends them), Compare with a Group (`GroupChoice.swift`), the first public posting dates seen (`FirstPostings.read`/`remember`; the merging is JTKit’s).
- `Logic/`: the text summary (`StatusSummary.swift`), Find a Device, the help texts, the CSV exports (`CSVExport.swift`), the Jamf Pro web addresses for Open in Jamf Pro (`JamfProPages.swift`), and `SharedRules.swift`: the names the app uses for JTKit’s software update rules. From JTKit 1.9.0 the rules themselves are JTKit’s (`SoftwareUpdateRules`): the target rules per device (`TargetRules`), the classifier and `DeviceStatus`, readiness, Inspect (`InspectFindings`, `InspectWorkflow`), deadlines per zone, Blueprint health, the server time zone check, and the reader of a refresh (`Reader`). `Workflows/RefreshWorkflow.swift` builds the dashboard’s `RefreshResult` from the reader’s reading (comparison group, tables, time zone check).
- `Automation/`: automatic refresh (`AutoRefresh`, all tracked Blueprints one after another, then one content cache sweep), keeping the Mac awake on power (`KeepAwake`), Open at login (`LoginItem`, the system's login item service), notifications per tracked Blueprint (`Notifier`, `RefreshNotices`).
- `Views/`: Content Caches (`CachesView.swift`: the page, the cache detail in an inspector, the caching Blueprint cards, and `SiteCachesSection`, the caches by site on a Blueprint’s dashboard and in the PDF), the main window, the Settings tabs General and Automation, the menu bar item, the notification sheet, the Help window (`HelpView`, its text and Known Problems in `Logic/HelpContent.swift`, each with a public Apple source), Find a Device (`FindDeviceSheet`, `Logic/DeviceSearch.swift`) and the PDF report (`ReportPDF`). None of these reads from Jamf.
- From JTKit 1.7.0: a mobile device's enrollment (`GroupMember.isUserEnrollment`) and the 1.7.0 demo cases; `ConnectionStore`, `ConnectionsSettingsTab`, `ConnectionPicker`/`ConnectionCommands`, `SettingsWindow`, `AboutWindow`, `UpdateChecker`, `ActivityLogWindow`, `DemoMode` with `DemoSoftwareUpdate`, `JamfPlatform.Client` and the 1.5.0 and 1.6.0 readers (groups and members with FileVault, `softwareUpdateStatus` with the declarations a device holds, raw `statusItems`, Declaration Reporting per device and per declaration, `softwareUpdateBlocks`), `AppleReleases`, `DemoSoftwareUpdate.pastRefreshes` and the demo release server’s `isUnreachable`, and `JTKitUITestCase.saveInTestFolder()` in the UI tests.
- From JTKit 1.11.0: `ContentCacheRules` (the sweep, health, savings, the series of sweeps), `DemoContentCaching`, `DeviceStatus.siteName`. The health thresholds are JTKit’s defaults (decided by Jordy on 2026-11-26; fullness is never a rule).
- Requires JTKit 1.13.1 or later (set in the project; Claude updates it).
- Every request goes through JTKit; the app only interprets. When something is needed that JTKit could share, extend JTKit instead of adding a copy here.
- Build facts: macOS 15.0, sandboxed (outgoing network, user-selected files read-write), Swift 5 mode with MainActor default isolation, bundle ID `be.jordythery.softwareupdatedashboard`. The "Run Build Number Script" phase stamps the built app's `CFBundleVersion` with a UTC date-time; nothing to commit.

## Rules

- **Read only.** The app never changes anything in Jamf: its clients allow GET and HEAD only (`ConnectionsModel.permits`), plus the sign-in. It asks only for read permissions: `blueprints:read`, `devices:read`, `device-groups:read`, `declarations:read`.
- **Term search.** Before every commit, run `../_release-gate/sud-scan.sh` (its terms are in `../_release-gate/sud-terms.txt`, outside every repo) and report the result. Never write the terms into the repo: not in code, comments, tests, docs or commit messages.
- **No real identifiers.** Never write a hostname, tenant name, serial or environment ID into the repo. Tests and scripts use role names and made-up values.
- No third-party code copied: JAMFGetDDMInfo is GPL and may only inform. Jordy’s own source app may be reused or adapted, but is never named in the repo.
- `os.Logger` messages that can hold server answers use `privacy: .private`.
- Demo mode never reaches a real tenant or the real release-data hosts (JTKit's demo network).
- Stored data: the connections under `connections` in UserDefaults, the one in use under `activeConnectionID`, the demo switch under `demoMode`, the tracked Blueprints under `trackedBlueprints` (moved once from the first version’s `trackedGroups`, which is read but never removed; a value that can’t be read is copied to `trackedBlueprints.unreadable-<date and time>` and never saved over; the banner can write that copy to `Application Support/Unreadable Copies/<key>.plist` for Finder, and Start a New List saves an empty `trackedBlueprints`, never touching the copy), the content caches in `ContentCaches/<connection ID>/` (one JSON file per sweep, `trend.index` with every cache of every sweep, `known-blueprints.plist` with the Blueprints known to have no caching declaration; kept as the history; Demo Mode’s in memory only), the history in `History/<tracked Blueprint ID>/`, with what that Blueprint’s devices reported about Jamf’s deadlines in `History/<tracked Blueprint ID>/reported-deadlines.plist` (`ReportedDeadlines`; Demo Mode’s in memory only), automatic refresh under `autoRefreshHours` and `keepAwake`, the first public posting date seen per platform, version and build under `firstPublicPostings` (Demo Mode's in memory only), the menu bar item under `showMenuBarItem`, the notification rules under `notificationRules` (Demo Mode's in memory only), the secrets in the Keychain under `be.jordythery.softwareupdatedashboard.jamf`. Keep these names.

## Watchlist

See WATCHLIST.md.

## Testing

- Unit tests: Swift Testing in `Software Update Dashboard Tests`, on JTKit's `MockServer` and demo mode; no real network.
- As the unit-test host, the app uses a throwaway UserDefaults domain and secrets in memory, so tests never touch real saved connections. Under tests every request for a saved connection is refused and written down (`UnderTest`). Every test that makes a `ConnectionsModel` passes its own settings (`TestFiles.defaults`); the shared preview domain is for Xcode previews only.
- Live checks use only the allow-list's read-only production role (`jamfpro-production`), reads only. Never write its hostname or tenant name into the repo. The content cache sweep's live check (`LiveCacheSweepTests`) reports counts only: pages read, caches found, caching Blueprints found, problems.
- New UI test targets are added by Jordy with Xcode's new-target tool.
- Ask Jordy before starting a release check or any UI test; once he says go, it may run unattended (start with `nohup`, then poll).
- UI tests live in `Software Update Dashboard UITests` (JTKitUITestCase): `DemoSmokeUITests` for the release check, `ScreenshotUITests` for the README's and website's screenshots in `docs/` (skipped by the release check). Both run only in Demo Mode.
- The release check: `Scripts/release-check.sh`; a full run reads the production role, so it needs `--include-production` (or the allow-list's `productionReads`).
- Branch `snapshots` (public): main plus the snapshot tool (`Scripts/snapshot.sh`, one anonymized read-only snapshot of the production role, written outside the repo); never commit snapshot output to it.

## Releasing

Follow the release gate in JTKit/ROADMAP.md.

1. Bump `MARKETING_VERSION` (and `CURRENT_PROJECT_VERSION` by one) in the project.
2. Add the version's entry to CHANGELOG.md (`## X.Y.Z — YYYY-MM-DD`, end-user bullets).
3. Update the README if features changed (its screenshot must show no real identifiers).
4. Jordy does the Developer ID signing and notarization himself, archiving from the app's own project; Claude never signs or notarizes (JTKit/CLAUDE.md, “Releasing an app”). Check the notarized app he supplies: `CFBundleShortVersionString` matches the tag, `codesign --verify --deep --strict`, `spctl -a`, `xcrun stapler validate`. Zip it with `ditto -c -k --keepParent` as `Software-Update-Dashboard-X.Y.Z.zip`, unzip a copy elsewhere and check it again.
5. After Jordy approves the notes, tag `vX.Y.Z` and create the GitHub release with the notes and the zip. Release notes (CHANGELOG entries and GitHub release notes) are for the end user: professional and concise, saying what changed for them, and never mentioning the release check, reviews, tests, test targets, AI tools, JTKit step numbers or how a problem was found (decided by Jordy on 2026-11-01).
6. Merge main into `snapshots` and push it, so the snapshot tool reads with the released rules.
7. Website: follow ../jordythery.be/CLAUDE.md, section “When an app is released”.
