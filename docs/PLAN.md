# Software Update Dashboard: plan

Decided by Jordy on 2026-11-09.

## What it is

A read-only Mac app that answers, for a group of devices, whether they are on the OS version their Blueprint’s software update asks for, and if not, why not.

The unit of work is a **tracked group**: a Jamf Pro group (mobile devices or computers) plus the Blueprint that enforces its update. For a tracked group, the app:

- reads the Blueprint’s software update: target version, build, deadline, and its blocks (the steps that hold a software update, each with its own activation predicate);
- reads each device’s inventory and its declarative device management (DDM) status items, and the declaration reports;
- sorts every device into nine categories with a plain-language diagnosis: on target, no report, unsupported, offline, no activity, other update, failed, in progress, not started;
- keeps a history per refresh, 180 days per tracked group;
- marks unsupported hardware, with a replacement list (model, number of devices, last version it can run);
- shows the deadline per time zone (the deadline is the device’s local time) and points out unusual zones;
- has an overview of all tracked groups, a dashboard per group, a device list and a device detail with Inspect, and CSV and summary exports.

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
| Computer inventory | `pro/v4/computers-inventory` | `devices:read` |
| DDM status items | `pro/v1/ddm/{clientManagementId}/status-items` | `devices:read` |
| Declaration reports | `ddm/report/v1/devices/{deviceId}/declarations`, `…/declarations/{id}/devices` | `declarations:read` |
| Platform devices (serial to device ID) | `devices/v1/devices` | `devices:read` |
| Apple releases | `sofafeed.macadmins.io/v2/{ios,macos}_data_feed.json`, `gdmf.apple.com/v2/pmv` | none |

### Where the code comes from

- Every request goes through JTKit 1.5.0 (see JTKit’s ROADMAP, "1.5.0 (Software Update Dashboard)"). SUD only interprets.
- The categories, classifier and diagnoses, summary, history and Inspect are copied from Jordy’s own earlier app and adapted, with typed models. Nothing of that app’s customer appears here: not its name, the app’s name, device classes, its concepts, device counts, serials or sample data, in code, comments, tests, docs or commit messages. Before every commit the repo and its commit messages are searched for those terms (the list is kept outside the repo).
- No code is copied from any other project.

### Order

On branch `milestone-1` (SUD) and `1.5.0` (JTKit):

1. The JTKit readers, with Swift Testing tests and no real network.
2. SUD’s app shell to JTKit’s standards: About, Settings with Connections and Updates, the Connection menu, the activity log, Demo Mode, the build-number script, LICENSE (MIT), README, CLAUDE.md (runs `check-versions.sh`).
3. The copied logic with its tests.
4. A mobile group end to end, in Demo Mode and on the allow-list’s read-only production role.
5. Every app in `Apps.xcworkspace` builds; then Jordy’s check by hand. JTKit isn’t tagged before Jordy approves.

### Later

- Computer groups end to end (the readers are in JTKit 1.5.0).
- The release check with its UI smoke tests in Demo Mode.
- Other MDMs.
