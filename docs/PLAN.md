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

Also for 0.2 (noted by Jordy on 2026-11-10, after the 0.1.1 hand check): Macs with a pending 27.2 and a 19 Nov deadline, this Blueprint’s step before 27.2.1, still show target 27.2 instead of 27.2.1 with “an earlier step”. Treat them like the 26.7.2 case: the Blueprint’s current target and deadline, with the step shown.

### Step 1: JTKit 1.6.0 (in Apps.xcworkspace)

Only what talks to vendors:

- A declaration’s device list (`ddm/report/v1/declarations/{id}/devices`) answers 400 without a filter: the reader sends `active==true,active==false`, with a test.
- Raw status items of every value type (strings, numbers, booleans, objects).
- A Mac’s FileVault (`DISK_ENCRYPTION`).
- Mac status items for battery health and Rapid Security Responses (supplemental build, extra version).
- Demo data for all of it (invalid and failed declarations, activations with predicates, awaiting sync, an unsupervised device, a Rapid Security Response, a long install), plus the samples noted for SUD in the release gate’s list of JTKit candidates.

Keep awake, the automatic refresh scheduler, notifications, the help window, the menu bar item and open at login stay in SUD; they move to JTKit only when a second app needs them.

Done on branch `release-1.6.0` (JTKit) on 2026-11-10, not tagged; see JTKit’s CHANGELOG. Added by Jordy on 2026-11-10: the identifiers of a device’s declarations from its `management.declarations` status item (`SoftwareUpdateStatus.declarationIdentifiers`), and a UI test check that a Save panel shows the test’s own folder before it saves.

### Step 2: release 0.2

Renumbered by Jordy on 2026-11-10: what branch `0.2` holds is release 0.2, built with JTKit 1.6.0 (JTKit is tagged only once SUD uses every new reader, and only after Jordy approves): Blueprint health (F), device details (H), all status items of a device (E), and the fixes below. The other features move to 0.3 (step 3).

- **F, Blueprint health:** read per declaration, never per device. The identifiers are those of this Blueprint among the declarations the devices list in their status reports (`management.declarations`), so no extra request finds them; a declaration no device has received isn’t listed. Each is read once per refresh (`declarations/{id}/devices`). A report is tied to a device through the Platform device ID SUD finds by serial number; a report that can’t be tied is left out and counted in a note. Names come from the predicate (versions, OS family) or the step, never IDs. A device whose Blueprint ranges for its hardware all end below its version, while its target is newer, is “Jamf’s update doesn’t cover ‹OS› ‹version› yet” in the list (when it is not started or has no activity), counted on the dashboard and in the summary. Not kept in the history.
- **H, device details:** Rapid Security Response (status report, else inventory), beta program, install reason, failure count and time, FileVault (`DISK_ENCRYPTION`), battery health (status report, else inventory); in the CSV as six new columns at the end.
- **E, all status items:** read when asked from the device detail, every value type, with a filter and Copy; not saved.
- **This Blueprint’s earlier step after Apple replaced it** (the 0.2 note): Apple’s public catalog can drop the earlier version’s posting once it posts the newer one. A reported deadline also counts as the step’s when it falls on a day the rule could have given that version while it was the rule’s target (from its release, or posting, to the next version’s posting), at the Blueprint’s time of day; a declaration report awaiting sync supports a version the rule targeted in that window.

**Round 2** (decided by Jordy on 2026-11-10, after an independent review and a hand check on the live tenant):

- The Platform device list is read once per refresh (JTKit `devices()`, paged) and matched by serial number; a failed read is an error, never “serial not found”. Only the Blueprint’s software update declarations count (by step and component in the identifier), and awaiting sync only for the device’s own OS. Apple’s posting date of the earlier step (from its other list) comes before the window; with the device’s zone known the full clock time counts. A stopped refresh is never saved.
- “Jamf’s update doesn’t cover …” only when the Blueprint’s current declarations don’t cover the version; when one does but the device’s report is older, “Hasn’t fetched Jamf’s current declarations yet (last reported …)”. An update error since the update started ranks above both. A failed or invalid update declaration of the device’s own OS is the list diagnosis of a device that hasn’t started.
- Inspect lists the current declarations for the device’s own platform, each named by its own platform and versions, with the rest in one line. Blueprint health merges pairs with the same range into one row and collapses rows that apply to no device in scope into one line.
- “Failures: 0” shows no date. Deadline per Time Zone lists a device past its earlier step’s deadline under that step.

Before the release: one read of the production role, and JTKit tagged after Jordy approves.

### Step 3: 0.3

| | Feature |
|---|---|
| A | Open in Jamf Pro: the Jamf Pro web address comes from the API when it gives one, otherwise from a field per connection (JTKit’s “Jamf Pro Web Address”); the device (detail, context menu, Device menu ⌥⌘O, asks first above 10) and the Blueprint. |
| B | Automatic refresh (in SUD) in a new Automation settings tab: off, every 1, 4 or 8 hours, all tracked Blueprints one after another; every refresh is saved in the history; a line on the Overview with the last and next refresh and any error; a Stop button. |
| C | Keep this Mac awake while automatic refresh is on: off by default, and only while the Mac is on power. After a sleep, automatic refresh catches up instead. |
| M | Open at login. |
| L | Menu bar item: the share on target with a colored dot, the tracked Blueprints, Refresh All, Open Window. |
| D | Notifications per tracked Blueprint: the share on target reaches or drops below a level; devices newly failed or stuck. Only changes between two refreshes notify. |
| G | Readiness: devices not supervised, without declarative device management, or that never reported; each number opens those devices. |
| I | Help › Software Update Dashboard Help: how each category is decided, and Known Problems, only problems with a public source (Apple’s or Jamf’s documentation), each linked in the list, e.g. the bootstrap token and Apple’s network access; Inspect links to them. In the app’s own words. |
| J | Export Report as PDF, one Blueprint or all (nice to have). |
| K | Find a device by serial number or name across all tracked Blueprints (nice to have). |

Also in 0.3 (decided by Jordy on 2026-11-10, after the 0.2 hand checks):

- A device with update failures since the update started and nothing in progress counts as Failed, not Not started.
- Deadline per Time Zone still shows one device on the live tenant as “target 27.2.1, 9 Nov 23:59” without the earlier-step label: find that device, the pending version and deadline it reports and why it isn’t recognized as an earlier step, then label it.
- A device on target lists no update errors from before it installed the target under Also Found.

Order: A, B with C and M, L, D, G, I, J, K (as planned for 0.2 before the renumbering). Each with tests and a check in Demo Mode; one read of the production role before the release.

**Round 1** (on branch `0.3`, 2026-11-10): the three items above, A and G.

- A: the Platform API gives the Jamf Pro web address only with another permission (`jss-url:read`) or an organization-level sign-in, so it comes from the connection’s Jamf Pro Web Address field (decided by Jordy on 2026-11-10). Demo Mode opens nothing and shows the page instead.
- The “27.2.1, 9 Nov 23:59” device: a Mac on 27.2 reporting 27.2.1 pending with 27.2’s deadline (its release on 26 Oct plus the Blueprint’s days); the earlier step was looked for only when the pending version is older than the target. Now the Blueprint’s current deadline counts and the kept deadline is shown, in Deadline per Time Zone as “27.2.1, with the deadline of earlier step 27.2”. Also: an earlier step’s deadline counts from every posting date Apple’s list still has for the version (Jamf counted 27.2 from 5 Nov, another build’s posting).
- G: not supervised (iPhones and iPads only), no declarative device management, never reported (no status report at all).

**Round 2** (on branch `0.3`, 2026-11-10, after Jordy’s hand check of round 1; with JTKit 1.7.0 on its branch `release-1.7.0`, decided by Jordy):

- Readiness: Apple’s `com.apple.configuration.softwareupdate.enforcement.specific` allows supervised and device enrollments on iOS and iPadOS and supervised enrollments only on macOS. “Not supervised” is replaced by iPhones and iPads enrolled with User Enrollment (JTKit 1.7.0 reads `deviceOwnershipType` and `appleEnrollmentType` from the inventory it already reads; Apple’s type first) and Macs that aren’t supervised. Checked on the live tenant: every iPad Institutional, none with User Enrollment, every Mac supervised.
- An older pending version of the rule’s major, reported with exactly the deadline the rule gives the rule’s version, while Apple’s data lists that version for the device: the rule’s version and deadline are the target, the pending version this Blueprint’s earlier step (seen on the live tenant: two iPads with 27.2 pending, due 16 Nov, the 27.2.1 deadline).
- Past the deadline: the live tenant had two Macs at “26.7.2, earlier step, 9 Nov”: one downloaded and late (counted), one still installing (not counted, listed anyway). Deadline per Time Zone now lists a device at a passed step deadline only when it counts as past it (also when the step failed); a device still installing is listed at its current target’s deadline. A device holding an earlier step’s deadline for its current target is labeled at the deadline that counts.
- Hardware to Replace: a device is marked only when it can’t run what the rule gives it (latest: the newest release; minor: its own major’s newest; a specific version: that version).
- The device detail shows a pending version already installed as ignored.
- B, C, M, L and D in SUD. The Stop button stops the automatic refresh that runs; automatic refresh stays on. Demo Mode’s notification rules are kept in memory and Demo Mode sends nothing (it writes what it would send in the activity log); the demo data doesn’t change between refreshes, so no notification is shown there.
- Demo data (JTKit 1.7.0): Studio Mac 09 (27.0.2 pending with 27.1’s deadline), Studio Mac 10 (27.0.2 failed, past its deadline), Studio Mac 11 (a 2018 MacBook Pro on 15.7.3, not supervised), Field iPad 14 (User Enrollment).

### Later

- Computer groups end to end (the readers are in JTKit 1.5.0).
- Other MDMs.
