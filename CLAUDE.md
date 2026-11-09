# Software Update Dashboard: instructions for Claude

At the start of every conversation, run ../JTKit/Scripts/check-versions.sh (or fetch it from GitHub if ../JTKit isn't there) and mention the result in one line if anything is out of date.

Shared code and the standards for every app: see JTKit's CLAUDE.md and ROADMAP.md (github.com/JordyThery/JTKit, or ../JTKit in the workspace). The plan for this app is docs/PLAN.md.

## What the app does

A read-only Mac app that answers, for a group of devices, whether they are on the OS version their Blueprint's software update asks for, and if not, why not. The unit of work is a tracked group: a Jamf Pro group (mobile devices or computers) plus the Blueprint that enforces its update. Milestone 1: Jamf Pro through the Jamf Platform API, iOS, iPadOS and macOS.

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
- `Views/`: the main window.
- From JTKit: `ConnectionStore`, `ConnectionsSettingsTab`, `ConnectionPicker`/`ConnectionCommands`, `SettingsWindow`, `AboutWindow`, `UpdateChecker`, `ActivityLogWindow`, `DemoMode` with `DemoSoftwareUpdate`, `JamfPlatform.Client` and the 1.5.0 readers (groups and members, `softwareUpdateStatus`, Declaration Reporting, `softwareUpdateBlocks`), `AppleReleases`.
- Every request goes through JTKit; the app only interprets. When something is needed that JTKit could share, extend JTKit instead of adding a copy here.
- Build facts: macOS 15.0, sandboxed (outgoing network, user-selected files read-write), Swift 5 mode with MainActor default isolation, bundle ID `be.jordythery.softwareupdatedashboard`. The "Run Build Number Script" phase stamps the built app's `CFBundleVersion` with a UTC date-time; nothing to commit.

## Rules

- **Read only.** The app never changes anything in Jamf: its clients allow GET and HEAD only (`ConnectionsModel.permits`), plus the sign-in. It asks only for read permissions: `blueprints:read`, `devices:read`, `device-groups:read`, `declarations:read`.
- **No customer data.** This app's logic was adapted from Jordy's own earlier app. Nothing of that app's customer may appear here: not its name, that app's name, its device classes or concepts, device counts, serials or sample data, in code, comments, tests, docs or commit messages. Before every commit, run `../_release-gate/sud-scan.sh` (the terms are in `../_release-gate/sud-terms.txt`, outside every repo) and report the result. Never write the terms into the repo.
- **No real identifiers.** Never write a hostname, tenant name, serial or environment ID into the repo. Tests and scripts use role names and made-up values.
- No code copied from other projects. JAMFGetDDMInfo is GPL and may only inform.
- `os.Logger` messages that can hold server answers use `privacy: .private`.
- Demo mode never reaches a real tenant or the real release-data hosts (JTKit's demo network).
- Stored data: the connections under `connections` in UserDefaults, the one in use under `activeConnectionID`, the demo switch under `demoMode`, the secrets in the Keychain under `be.jordythery.softwareupdatedashboard.jamf`. Keep these names.

## Watchlist

See WATCHLIST.md.

## Testing

- Unit tests: Swift Testing in `Software Update Dashboard Tests`, on JTKit's `MockServer` and demo mode; no real network.
- As the unit-test host, the app uses a throwaway UserDefaults domain and secrets in memory, so tests never touch real saved connections. Under tests every request for a saved connection is refused and written down (`UnderTest`).
- Live checks use only the allow-list's read-only production role (`jamfpro-production`), reads only. Never write its hostname or tenant name into the repo.
- New UI test targets are added by Jordy with Xcode's new-target tool. Run a single UI test only when Jordy asks for it by name.

## Releasing

Follow the release gate in JTKit/ROADMAP.md.

1. Bump `MARKETING_VERSION` in the project.
2. Update the README if features changed (its screenshot must show no real identifiers).
3. Archive from the app's own project, sign with Developer ID, notarize, and zip.
4. Tag `vX.Y.Z`, create the GitHub release with notes and attach the zip. Release notes (CHANGELOG entries and GitHub release notes) are for the end user: professional and concise, saying what changed for them, and never mentioning the release check, reviews, tests, test targets, AI tools, JTKit step numbers or how a problem was found (decided by Jordy on 2026-11-01).
5. Website: follow ../jordythery.be/CLAUDE.md, section “When an app is released”.
