# Changelog

## Unreleased

### New

- Tracked Blueprints: the devices of a Blueprint’s scope, each counted once, with scope changes in the history and an optional comparison with any group.
- A target per device from the Blueprint’s software update and Apple’s release data, with its deadline in the device’s local time, and a table per major release.
- An “Update started” date per Blueprint, set by hand.
- Every device sorted into nine categories, with a plain-language diagnosis of why it isn’t on the target version yet. A device whose target can’t be determined is shown as “Target unknown” with the reason, and left out of the counts and the history.
- When Apple’s release data can’t be read, a refresh stops with that reason and the previous refresh stays on screen.
- Exported CSV files show cells that look like spreadsheet formulas as text.
- Stop Tracking asks for confirmation, as it deletes the Blueprint’s history.
- A device’s target is the version Jamf sent it, as the device reports it pending, when there is one; the device detail shows the Blueprint’s rule beside it and points out when they differ.
- Intel Macs are matched to Apple’s release lists correctly and get their major’s newest release.
- Inspect no longer reports update declarations meant for other versions as failures, names declarations by Blueprint and versions, and shows a Mac’s bootstrap token status.
- Deadlines a device reports are shown as that moment in this Mac’s time zone, marked “reported by the device”; computed deadlines are in the device’s local time. By Major Release lists each deadline once.
- A downloaded update counts as stuck only when it hasn’t installed after its deadline, and never for an offline device.
- Inspect says when a device hasn’t evaluated the current update declarations yet, and checks the device’s own hardware ID against them.
- Hardware that can’t run the newest major stays in Hardware to Replace, also when its target comes from the device.
- The device detail says where the target comes from.
- Connections to the Jamf Platform API with read permissions only. The app never changes anything in Jamf.
- Demo Mode with sample iPads and Macs in the middle of an update.
