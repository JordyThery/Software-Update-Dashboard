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
- Connections to the Jamf Platform API with read permissions only. The app never changes anything in Jamf.
- Demo Mode with sample iPads and Macs in the middle of an update.
