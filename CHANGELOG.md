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
- Intel Macs reporting `X86LEGACYAP` get their major’s newest release.
- Inspect no longer reports update declarations meant for other versions as failures, names declarations by Blueprint and versions, and shows a Mac’s bootstrap token status.
- Deadlines a device reports are shown as that moment in this Mac’s time zone, marked “reported by the device”; computed deadlines are in the device’s local time. By Major Release lists each deadline once.
- A downloaded update counts as stuck only when it hasn’t installed after its deadline, and never for an offline device.
- Inspect says when a device hasn’t evaluated the current update declarations yet, and checks the device’s own hardware ID against them.
- Hardware that can’t run the newest major stays in Hardware to Replace, also when its target comes from the device.
- The device detail says where the target comes from.
- Deadlines count from Apple’s public posting date of the release, as Jamf does, and the device detail says where each deadline comes from. A deadline a device reported before the Blueprint’s last change is shown but not used.
- A release becomes the target from the day Apple offers it publicly; the Blueprint’s delay sets its deadline, as Jamf does.
- A refresh in which no device has a target isn’t saved in the history.
- The CSV export writes a reported deadline with its time zone and says where each deadline comes from.
- When the saved list of tracked Blueprints can’t be read, its copy can be shown in Finder and a new list started.
- Connections to the Jamf Platform API with read permissions only. The app never changes anything in Jamf.
- Demo Mode with sample iPads and Macs in the middle of an update.
