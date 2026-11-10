# Changelog

## 0.1.1 — 2026-11-10

- **When Apple posts a newer version during an update,** a device still installing the Blueprint’s earlier version is measured against the newer one and its deadline, and shown as installing the earlier version first. It no longer counts as past its deadline.
- **A device that installed but hasn’t reported it yet** counts as on its new version, using the newer of the version it reports and the one in Jamf Pro’s inventory.
- **An update that has been installing for more than 4 hours** is pointed out when the device keeps checking in without reporting a new status.
- **A downloaded update** is called stuck only some hours after its deadline, not the moment the deadline passes.
- **Inspect** shows each declaration’s exact version range (for example macOS 26.0 to 26.7.1), counts only the declarations for the device’s own OS, and says when Jamf’s update doesn’t cover the device’s version yet or when the device hasn’t fetched a new declaration. An error from before the update started is listed, but never given as the likely cause.
- **Dashboard:** By Major Release shows the Blueprint’s deadline once, with the number of devices that report another one; Deadline per Time Zone explains Macs’ missing time zone once; the history chart shows steps between refreshes, marks when an Apple release moves the targets, and labels its scale as devices.
- **History** no longer marks a change of the Blueprint’s software update when only this Mac’s region or clock format changed.
- A target that is the newest a model can run is explained in a help tag and to VoiceOver, not by its color alone.

## 0.1.0 — 2026-11-09

The first release.

- **Track a Blueprint’s software update:** for the devices in the groups a Blueprint is scoped to (iPads, iPhones and Macs), see which are on the OS version the Blueprint asks for, and why the others aren’t yet.
- **A target and a deadline per device,** from the Blueprint and Apple’s release data, in each device’s local time.
- **Every device in a category with a plain-language diagnosis,** and Inspect for the likely cause on a single device.
- **A dashboard per Blueprint:** progress, history, deadlines per time zone and hardware to replace. The device list and a summary can be exported.
- **Read only:** connects to the Jamf Platform API with read permissions only, and never changes anything in Jamf.
- **Demo Mode** with sample iPads and Macs, to try the app without a Jamf tenant.
