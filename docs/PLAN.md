# Software Update Dashboard: plan

Decided by Jordy on 2026-11-09.

## What it is

A read-only Mac app that answers, for the devices a Blueprint is scoped to, whether they are on the OS version its software update asks for, and if not, why not.

The unit of work is a **tracked Blueprint**: a Blueprint with a software update (changed from a tracked group by Jordy on 2026-11-09). Its devices are those of the Jamf Pro groups it is scoped to, mobile devices and computers together, each device counted once; the scope is read again on every refresh and its changes are kept in the history. A group can be added for comparison: its devices the Blueprint doesn’t reach (a coverage check, not counted). For a tracked Blueprint, the app:

- reads the Blueprint’s software update: target version, build, deadline, and its blocks (the steps that hold a software update, each with its own activation predicate);
- reads each device’s inventory and its declarative device management (DDM) status items, and the declaration reports;
- sorts every device into nine categories with a plain-language diagnosis: on target, no report, unsupported, offline, no activity, other update, failed, in progress, not started; a device without a target (Apple’s data unreachable, no software update, no release for its platform, a beta of a newer major) is “Target unknown” with its reason, outside every count and the history, and a refresh without Apple’s data stops and keeps the previous one;
- gives every device its own target (see below) and keeps a history per refresh, 180 days per tracked Blueprint;
- marks unsupported hardware, with a replacement list (model, number of devices, last version it can run);
- shows the deadline per time zone (the deadline is the device’s local time) and points out unusual zones;
- doesn’t save a refresh in which no device has a target (the chart would drop to zero), and says so;
- exports a reported deadline in the CSV as a UTC moment (`Z`), with the deadline’s source in its own column;
- has an overview of all tracked Blueprints, a dashboard per Blueprint (with a table per platform and major release), a device list and a device detail with Inspect, and CSV and summary exports.

### Inspect (decided by Jordy on 2026-11-09)

- A minor-updates Blueprint sends one configuration and activation pair per version range, each with a predicate (OS family, version range, board IDs or models). Each configuration is judged with its own activation (`…_cfg12` with `…_act12`). A pair whose activation reports `Info.Predicate` is “not for this device”, so its configuration’s `Error.ActivationFailed` isn’t a failure. Every other `Error.*` is a failure, as is an invalid declaration.
- Declarations are named by their Blueprint and the versions they are for (“‹Blueprint›, macOS 26.0 to 26.7.1”, from the predicate, to the patch), never by IDs, server tokens or hashes.
- **Stuck** only when a downloaded (prepared) update hasn’t installed after its deadline; before it, it installs at the deadline. Never for an offline device. Durations over 48 hours in days.
- **A stale declaration report:** when the device last reported its update declarations before the update started or the Blueprint’s last change, Inspect says “Not evaluated since the update started” as the likely cause. “Doesn’t apply” comes only from a current report, with the device’s own device ID (or model) checked against the predicates’ lists.
- **Bootstrap token:** a Mac’s bootstrap token status comes from the inventory’s `SECURITY` section (`bootstrapTokenEscrowedStatus`, `bootstrapTokenAllowed`), shown in the device detail. When the last error names the bootstrap token, it is the likely cause; a token that isn’t escrowed is listed otherwise.

### Targets per device (decided by Jordy on 2026-11-09)

Jamf’s reference (Platform API, Blueprint schema) has three software update settings, plus Apple’s own declaration:

| Setting | Target of a device | Reports count from | Deadline |
|---|---|---|---|
| Specific version (`MANUAL`, no delay) | that version | the Blueprint’s last change | the Blueprint’s, device local time |
| Latest (`AUTOMATIC` `LATEST`, 0–30 days) | Apple’s newest public release, across majors, from the day Apple posts it publicly; the newest its model can run (listed among the hardware to replace, with a note) | Apple’s first release date of the target | public posting date + days, at the Blueprint’s time, device local time |
| Minor updates (`AUTOMATIC` `SEMANTIC` `minor`, 0–30 days) | the newest public release of its own major, from the day Apple posts it publicly | Apple’s first release date of the target | public posting date + days, at the Blueprint’s time, device local time |
| Apple’s declaration (custom declarations) | as a specific version, with its build | as a specific version | as a specific version |

The days are the time until the deadline, not a wait before a release becomes the target (decided by Jordy on 2026-11-09, as Jamf does it on the tenant: macOS 27.2 sent after its 5 Nov public posting, due 19 Nov with 14 days). The detail says it so: “The newest public macOS 27 release: 27.2; installs by 19 Nov”.

- **A stale report** (decided by Jordy on 2026-11-09): a reported deadline for the rule’s own version counts only when the report is newer than the Blueprint’s last change and, for latest and minor, Apple’s public posting of the version. Otherwise the rule’s deadline counts and the device detail and Inspect say which of the two the report predates; when the rule has no deadline, the reported one stays, labeled as possibly out of date. Not raised when both deadlines fall on the same day.
- **What Jamf sent comes first** (decided by Jordy on 2026-11-09). When a device reports a pending version (`softwareupdate.pending-version`) with an install reason that includes `declaration`, newer than what it runs and reported after the update started, that version is its target, with the deadline it reports (a moment with an offset; the offset places the device in Deadline per Time Zone). When the rule above gives another version, the detail shows both and flags that another declaration may be enforcing this. For a specific version a lower pending version is an intermediate step, and the Blueprint’s version stands. Pending versions that are stale (equal to or older than the installed one) or come from another reason (`notification`, none) are ignored. Otherwise the rule above, from Apple’s data, applies.
- **This Blueprint’s earlier step** (decided by Jordy on 2026-11-10): when the pending version is one this Blueprint itself sent before Apple posted a newer one, and its rule now gives that newer version, the newer version and its deadline count. The device is “Other update: installing ‹pending› first”; the earlier deadline is shown in the detail (“earlier step of this Blueprint”) and isn’t counted as past. Jamf’s status items don’t name the declaration that sent a pending version, so it is this Blueprint’s earlier step only with evidence: the reported deadline equals this Blueprint’s deadline for that version (its posting date plus the days, at the Blueprint’s time), or the Blueprint’s declaration report for the device says awaiting sync. Without evidence the rule above (what Jamf sent comes first) stands. A pending version counts as an earlier step only when the device reported it after the update started; an older report affects neither the target nor the deadline. A late step never replaces the target (decided by Jordy on 2026-11-10, after review and a hand check): once it isn’t installing and its own deadline plus the 4-hour grace has passed, the target stays the Blueprint’s current one and the device counts as past the step’s deadline, with a diagnosis that names it (“26.7.2 downloaded but not installed after its deadline”).
- **Installing for a long time** (decided by Jordy on 2026-11-10): a device that reports installing for more than 4 hours and has contacted Jamf at least 30 minutes after that status is flagged “Installing for more than 4 hours; the device checks in but hasn’t reported a new status”, and stays In progress. When its inventory already shows the pending version, the newer of the inventory and reported versions counts (installed, status not updated yet). Without contact since it started, the detail says “no contact since it started installing”, not a warning.
- **Matching Apple’s release lists:** by the device’s own `softwareupdate.device-id` first, then its model, and only when Apple lists that ID for the release’s major. A device the lists don’t recognize (Intel Macs report `X86LEGACYAP`) is unknown, never unsupported: it is judged by the major and gets that major’s newest release, never an older one only because that one has no device list. The target and the replacement list use the same rule.
- A device that already runs a release Apple shipped to it, old enough for the rule and newer than the rule’s target, is “Target unknown” (the rule doesn’t fit it), never measured against a lower target.
- A device is unsupported only when no release applies to its hardware at all.
- An “Update started” date per tracked Blueprint, set by hand, overrides where reports count from; it is shown wherever it applies and can be removed.
- Macs have no time zone in Jamf Pro: their deadline is “device local time”.
- **Showing deadlines** (decided by Jordy on 2026-11-09): a deadline a device reports is a moment (Macs write it in UTC, e.g. 22:59 +0000 for 23:59 in Amsterdam; the offset says nothing about the device’s zone). It is shown in this Mac’s time zone, “reported by the device”; a computed one as “device local time”. Deadline per Time Zone never groups by the offset. By Major Release lists each distinct deadline once.
- The device detail says where the target comes from: sent by Jamf (matching the Blueprint’s rule or not), the version the Blueprint names, or Apple’s data with the rule.
- **Where a deadline comes from** (decided by Jordy on 2026-11-09, as Jamf does it): a deadline the device reports wins when the report is newer than the Blueprint’s last change and Apple’s public posting of the version; an older one is shown as “reported before the Blueprint’s last change”, the rule’s deadline counts for past the deadline, late and stuck, and Inspect says “Declaration not refreshed since the Blueprint changed”. Otherwise Apple’s public posting date of the release meant for the device (GDMF `PublicAssetSets`; Apple can post a version in several builds, each for its own devices) plus the delay, at the Blueprint’s time of day, for every platform. Without a posting date, the first release date, and the detail says so. The detail shows the source: “reported by the device”, “set in the Blueprint”, “from Apple’s posting date”, “from the release date, no posting date found”. “Reports count from” stays at the first release date. A release is a target only once Apple offers it publicly (a public posting for the device; a release GDMF doesn’t list; or one listed only outside the public catalog with a newer public release of its major), from the day it is offered; a release GDMF lists only outside the public catalog and newer than every public one isn’t offered yet. Example: macOS 27.2 was released on 26 Oct and posted to the public catalog on 5 Nov, so with 14 days the deadline is 19 Nov.
- The separate software update settings component (deferrals, cadence, automatic actions, beta) is shown, not used for the target.

It never changes anything in Jamf. Its allow-list permits GET and sign-in requests only, and it asks only for read permissions.

## Milestone 1

Jamf Pro through the Jamf Platform API only, for iOS, iPadOS and macOS.

- **Connection:** one Jamf Platform API connection. Permissions: `blueprints:read`, `devices:read`, `device-groups:read`, `declarations:read`. Per connection, the time zone of the Jamf Pro server (status item times are its local time, with no zone), UTC by default.
- **Apple release data:** SOFA (Mac Admins Open Source) and Apple’s GDMF, for the latest versions, builds, supported models and the last version per model.

### Endpoints (Jamf’s API reference, Platform API)

| Read | Endpoint | Permission |
|---|---|---|
| Blueprints | `blueprints/v1/blueprints`, `…/{id}` | `blueprints:read` |
| Mobile device groups | `pro/v2/mobile-device-groups` | `device-groups:read` |
| Mobile group members with inventory | `pro/v2/mobile-device-groups/smart-group-membership/{id}`, `…/static-group-membership/{id}` | `device-groups:read`, `devices:read` |
| Computer groups | `pro/v1/computer-groups` | `device-groups:read` |
| Smart computer group members | `pro/v3/computer-groups/smart-group-membership/{id}` | `device-groups:read` |
| Static computer group members | `proclassic/computergroups/id/{id}` | `device-groups:read` (confirmed live) |
| Computer inventory (with `SECURITY` for the bootstrap token) | `pro/v4/computers-inventory` | `devices:read` |
| DDM status items | `pro/v1/ddm/{clientManagementId}/status-items` | `devices:read` |
| Declaration reports | `ddm/report/v1/devices/{deviceId}/declarations`, `…/declarations/{id}/devices` | `declarations:read` |
| Platform devices (serial to device ID) | `devices/v1/devices` | `devices:read` |
| Apple releases | `sofafeed.macadmins.io/v2/{ios,macos}_data_feed.json`, `gdmf.apple.com/v2/pmv` | none |

### Where the code comes from

- Every request goes through JTKit 1.5.0 (see JTKit’s ROADMAP, "1.5.0 (Software Update Dashboard)"). SUD only interprets.
- The categories, classifier and diagnoses, summary, history and Inspect are SUD’s own, with typed models, built on what JTKit reads.
- No code is copied from any other project.

### Order

On branch `milestone-1` (SUD) and `1.5.0` (JTKit):

1. The JTKit readers, with Swift Testing tests and no real network.
2. SUD’s app shell to JTKit’s standards: About, Settings with Connections and Updates, the Connection menu, the activity log, Demo Mode, the build-number script, LICENSE (MIT), README, CLAUDE.md (runs `check-versions.sh`).
3. SUD’s logic (categories, classifier and diagnoses, summary, history, Inspect) with its tests.
4. A mobile group end to end, in Demo Mode and on the allow-list’s read-only production role.
5. Every app in `Apps.xcworkspace` builds; then Jordy’s check by hand. JTKit isn’t tagged before Jordy approves.

## Next (decided by Jordy on 2026-11-10)

Read only throughout: nothing changes anything in Jamf (no sync, no update push, no inventory request). No new permissions are expected; the release check’s production read confirms it.

### Step 0: release 0.1.1, fixes

Found in a check of the live tenant on 2026-11-10. Released on its own, before 0.2, on branch `0.1.1`; no JTKit change (it builds against JTKit 1.5.0). In 0.1.1 the refresh finds this Blueprint’s earlier step by the reported deadline; awaiting sync is shown by Inspect, which reads the device’s declaration report (the refresh reads it once JTKit 1.6.0 can read a declaration’s devices).

1. With a delay of 0, call a downloaded update stuck only some time after the deadline, not the moment it passes.
2. Compare a Blueprint’s rule by its values, not its text, so a change of the Mac’s region or clock format adds no history mark.
3. Inspect: an error from before the update started is never the likely cause; it is listed under Also Found as an earlier error. The bootstrap token finding fits a token Jamf Pro reports as escrowed.
4. Inspect: exact version ranges from the predicate, to the patch (“macOS 26.0 to 26.7.1”, not “26.0–26.7”); only the declarations for the device’s own OS family are counted; shorter text (the Blueprint’s name once). A new likely cause when no declaration’s range covers the device’s version: “Jamf’s update doesn’t cover macOS ‹version› yet”.
5. This Blueprint’s earlier step: see “Targets per device”.
6. Installing for a long time: see “Targets per device”.
7. The diagnosis “Online, update not started (no error since the update started)” when an earlier error exists.
8. The orange target (the newest the model can run) explains itself as a help tag and for VoiceOver, never by color alone.
9. Dashboard: By Major Release shows the Blueprint’s deadline once plus “N devices report another deadline” (details on hover); Deadline per Time Zone shows the Mac warning once.
10. History chart: steps between refreshes instead of slopes; a mark when Apple posts a release that moves targets; the axis labelled as devices.
11. Watchlist: Jamf’s minor-update ranges can lag behind their targets (devices already on the previous release are then not covered); `softwareupdate.install-reason` names no declaration; a declaration’s device list needs a filter.

Also in 0.1.1 (decided by Jordy on 2026-11-10, after review and a hand check): an install state for a version the device already runs is ignored; “Jamf’s update doesn’t cover …” looks only at the device’s own major and only when the Blueprint asks for a newer version; “Apple released” is marked only after a lower target of the same OS and major; a stale declaration report is the likely cause only without a software update status since the update started, and a long install comes first; Deadline per Time Zone has one row per target and deadline moment (a Mac’s computed deadline in this Mac’s zone), and a reported deadline hours off the rest is pointed out.

Left for 0.2 (item F): the “Jamf’s update doesn’t cover …” cause in the device list, with a total on the dashboard. The Blueprint itself holds the rule only; Jamf’s version ranges come from the declaration reports, one request for each declaration.

### Step 1: JTKit 1.6.0 (in Apps.xcworkspace)

Only what talks to vendors:

- A declaration’s device list (`ddm/report/v1/declarations/{id}/devices`) answers 400 without a filter: the reader sends `active==true,active==false`, with a test.
- Raw status items of every value type (strings, numbers, booleans, objects).
- A Mac’s FileVault (`DISK_ENCRYPTION`).
- Mac status items for battery health and Rapid Security Responses (supplemental build, extra version).
- Demo data for all of it (invalid and failed declarations, activations with predicates, awaiting sync, an unsupervised device, a Rapid Security Response, a long install), plus the samples noted for SUD in the release gate’s list of JTKit candidates.

Keep awake, the automatic refresh scheduler, notifications, the help window, the menu bar item and open at login stay in SUD; they move to JTKit only when a second app needs them.

### Step 2: 0.2

| | Feature |
|---|---|
| A | Open in Jamf Pro: the Jamf Pro web address comes from the API when it gives one, otherwise from a field per connection (JTKit’s “Jamf Pro Web Address”); the device (detail, context menu, Device menu ⌥⌘O, asks first above 10) and the Blueprint. |
| B | Automatic refresh (in SUD) in a new Automation settings tab: off, every 1, 4 or 8 hours, all tracked Blueprints one after another; every refresh is saved in the history; a line on the Overview with the last and next refresh and any error; a Stop button. |
| C | Keep this Mac awake while automatic refresh is on: off by default, and only while the Mac is on power. After a sleep, automatic refresh catches up instead. |
| M | Open at login. |
| L | Menu bar item: the share on target with a colored dot, the tracked Blueprints, Refresh All, Open Window. |
| D | Notifications per tracked Blueprint: the share on target reaches or drops below a level; devices newly failed or stuck. Only changes between two refreshes notify. |
| G | Readiness: devices not supervised, without declarative device management, or that never reported; each number opens those devices. |
| H | Device details: Rapid Security Response, beta enrollment, install reason, failure count and time, FileVault, battery health; the useful ones in the CSV. |
| F | Blueprint health: each declaration by name (never IDs) with how many devices report it successful, pending, awaiting sync, failed or invalid, and the most common reason; devices whose version no declaration covers. Read per declaration, not per device. Inspect shows all of the Blueprint’s declarations for one device. |
| E | All status items of a device, read on request, with a filter and Copy; not kept in the history. |
| I | Help › Software Update Dashboard Help: how each category is decided, and Known Problems, only problems with a public source (Apple’s or Jamf’s documentation), each linked in the list, e.g. the bootstrap token and Apple’s network access; Inspect links to them. In the app’s own words. |
| J | Export Report as PDF, one Blueprint or all (nice to have). |
| K | Find a device by serial number or name across all tracked Blueprints (nice to have). |

Order: step 0 (released as 0.1.1), step 1, then A, B with C and M, L, D, G, H, F, E, I, J, K. Each with tests and a check in Demo Mode; one read of the production role before the release; JTKit is tagged only after Jordy approves.

### Later

- Computer groups end to end (the readers are in JTKit 1.5.0).
- Other MDMs.
