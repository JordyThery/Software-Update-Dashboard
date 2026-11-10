# Changelog

## 0.2 (not released yet)

- **Blueprint health:** each of the Blueprint’s software update declarations by name, one row per version range, with how many devices report it applied, pending, awaiting sync, failed or invalid, and the most common reason. Declarations that apply to no device in scope are summed up in one line. The dashboard says how many devices are on a version the Blueprint’s update doesn’t cover yet.
- **Clearer causes in the device list:** a version the Blueprint’s current declarations don’t cover yet; a device that hasn’t fetched Jamf’s current declarations yet, with when it last reported; a failed or invalid update declaration.
- **Inspect** lists the Blueprint’s current declarations for the device’s own platform, each named by its own versions, with how each one stands; the others are summed up in one line. An update error since the update started comes first.
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
