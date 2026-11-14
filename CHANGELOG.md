# Changelog

## 0.3.1 — Unreleased

- **Deadlines stay put when Apple re-dates a release.** When Apple changes the posting date of a release that was already public, the deadline no longer moves to the new date. The app uses the deadline Jamf sent, as the Blueprint’s devices report it, for every device of that Blueprint, including devices that haven’t reported it yet; their deadline says “As the Blueprint’s other devices report it”. Without such reports it counts from the first public posting date it saw. A deadline a device reported before the change is no longer marked as possibly out of date.

## 0.3.0 — 2026-11-10

- **Readiness** on the dashboard: how many devices can’t get an enforced update as they are: iPhones and iPads enrolled with User Enrollment, Macs that aren’t supervised, devices on an OS too old for update declarations (iOS and iPadOS 16 or earlier, macOS 13 or earlier), devices without declarative device management, and devices that never reported. Each number shows those devices in the list.
- **Help** (Help › Software Update Dashboard Help, ⌘?): how each category is decided, where a device’s target and deadline come from, what an earlier step of the Blueprint is, what Readiness counts and what Inspect does. Known Problems describes reasons an update doesn’t install, each with a link to Apple’s own page about it, and Inspect links to the problem it finds.
- **Find a Device** (⇧⌘F, also in the toolbar and the Device menu): a device by serial number or name in every tracked Blueprint, from its last refresh, opened in its Blueprint’s device list.
- **Open in Jamf Pro:** a device’s page (from its detail, the device list’s context menu, or Device › Open in Jamf Pro, ⌥⌘O) or the Blueprint’s page, in your browser. Device pages open read-only, and opening more than 10 devices at once asks first. It uses the Jamf Pro web address you add to the connection in Settings › Connections.
- **Export Report as PDF:** for the Blueprint on screen or all tracked Blueprints, with what the dashboard shows and the devices to check, from each Blueprint’s last refresh.
- **Automatic refresh** in a new Automation tab in Settings: off, or every 1, 4 or 8 hours. Every tracked Blueprint is read one after another and each refresh is kept in its history. The Overview shows the last and next refresh, any problem, and a Stop button while it runs. A refresh that fails keeps the previous one and is tried again at the next interval. It can keep this Mac awake while it’s on power (off by default); after a sleep it catches up once.
- **Open at login** and **Show in menu bar** in Settings › General. The menu bar item shows each tracked Blueprint’s share on target with a colored dot, Refresh All and Open Window.
- **Notifications per tracked Blueprint** (Blueprint › Notifications…): when the share on target reaches or drops below a level you choose, and when devices are newly failed or stuck. Only a change between two refreshes notifies. Permission is asked when you turn a notification on.
- **Refreshing** shows each step as it goes, for example “Reading Blueprint health, 3 of 18 declarations”, and can be stopped; the previous refresh stays.
- **The history** stays small and quick to read with frequent refreshes: counts are kept for 180 days, full refreshes for 7 days and then the newest of each day.
- **Earlier steps of the Blueprint** are recognized in more cases: a device that reports the older version pending with the newer version’s deadline, or the current version with the earlier step’s deadline, is measured against the Blueprint’s current version and deadline, with the earlier step shown. Deadline per Time Zone lists a device at an earlier step’s passed deadline only when it counts as past that deadline, so the dashboard’s number and the table agree.
- **Hardware to Replace** no longer lists a device that runs the newest release of its own major that Apple ships for its model, under a Blueprint for minor updates.
- **A device with update failures since the update started** and nothing in progress now counts as Failed instead of Not started.
- **Clearer diagnoses:** a download declined over a cellular connection (the device needs Wi-Fi), a passcode that has to be entered to install (also while the update downloads), and an OS too old for update declarations.
- **Battery** in Inspect follows Apple’s minimums: low under 20% or with a battery error; under 30% on iPhone and iPad an automatic install may wait for charging.
- **Inspect** no longer lists update errors from before a device on target installed its target.
- **The device detail** shows a pending version the device already runs as “already installed, ignored”.

## 0.2.0 — 2026-11-10

- **Blueprint health:** each of the Blueprint’s software update declarations by name, one row per version range, with how many devices report it applied, pending, awaiting sync, failed or invalid, and the most common reason. Declarations that apply to no device in scope are summed up in one line. The dashboard says how many devices are on a version the Blueprint’s update doesn’t cover yet.
- **Clearer causes in the device list:** a version the Blueprint’s current declarations don’t cover yet; a device that hasn’t fetched Jamf’s current declarations yet, with when it last reported; a failed or invalid update declaration.
- **Inspect** lists the Blueprint’s current declarations for the device’s own platform, each named by its own versions, with how each one stands; the others are summed up in one line. An update error since the update started comes first, unless the device has started downloading or installing since; an offline device is offline first.
- **Device details:** Rapid Security Response, beta program, why the pending update started, the number and time of failures, FileVault and battery health. The useful ones are also in the device list’s CSV.
- **All status items of a device,** read from Jamf Pro when asked, with a filter and Copy. They aren’t saved.
- **An earlier step of the Blueprint** is recognized also after Apple has replaced it in its public catalog, for example 27.2 due November 19 while the Blueprint now asks for 27.2.1: the device is measured against 27.2.1 and its deadline, with 27.2 shown as the step it installs first. Deadline per Time Zone lists a device past such a step’s deadline under that step.
- **A stopped refresh** is never saved in the history.

## 0.1.1 — 2026-11-10

- **When Apple posts a newer version during an update,** a device still installing the Blueprint’s earlier version is measured against the newer one and its deadline, and shown as installing the earlier version first. Once that earlier version’s own deadline has passed and it isn’t installing, the device keeps the newer target but counts as past its deadline, for example “26.7.2 downloaded but not installed after its deadline”. A pending version from a report older than the update’s start no longer affects the target or the deadline.
- **A device that installed but hasn’t reported it yet** counts as on its new version, using the newer of the version it reports and the one in Jamf Pro’s inventory. An install state left over from that install is ignored.
- **An update that has been installing for more than 4 hours** is pointed out when the device checks in with Jamf afterwards without reporting a new status.
- **A downloaded update** is called stuck 4 hours after its deadline, not the moment the deadline passes.
- **Inspect** shows each declaration’s exact version range (for example macOS 26.0 to 26.7.1) and counts only the declarations for the device’s own OS. It says when Jamf’s update didn’t cover the device’s version yet at the device’s last report, and when the device hasn’t fetched a new declaration. A device on target lists no declaration that doesn’t apply. A stuck install comes before an outdated declaration report. An error from before the update started, including one about the bootstrap token, is listed but never given as the likely cause.
- **The diagnosis** says “no error since the update started” when the device has only an older error.
- **Dashboard:**
  - By Major Release shows the Blueprint’s deadline once, with the number of devices that report another one and how many are past their deadline.
  - Deadline per Time Zone shows one row per target and deadline, points out a reported deadline hours off the rest, and explains Macs’ missing time zone once.
  - The history chart shows steps between refreshes, marks when an Apple release moves the targets, and labels its scale as devices.
- **History** no longer marks a change of the Blueprint’s software update when only this Mac’s region or clock format changed. The first refresh after updating is marked as an app update, as targets are now worked out a little differently.
- A target that is the newest a model can run is explained in a help tag and to VoiceOver, not by its color alone.

## 0.1.0 — 2026-11-09

The first release.

- **Track a Blueprint’s software update:** for the devices in the groups a Blueprint is scoped to (iPads, iPhones and Macs), see which are on the OS version the Blueprint asks for, and why the others aren’t yet.
- **A target and a deadline per device,** from the Blueprint and Apple’s release data, in each device’s local time.
- **Every device in a category with a plain-language diagnosis,** and Inspect for the likely cause on a single device.
- **A dashboard per Blueprint:** progress, history, deadlines per time zone and hardware to replace. The device list and a summary can be exported.
- **Read only:** connects to the Jamf Platform API with read permissions only, and never changes anything in Jamf.
- **Demo Mode** with sample iPads and Macs, to try the app without a Jamf tenant.
