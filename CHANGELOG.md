# Changelog

## 0.1.0 — 2026-11-09

The first release.

- **Track a Blueprint’s software update:** for the devices in the groups a Blueprint is scoped to (iPads, iPhones and Macs), see which are on the OS version the Blueprint asks for, and why the others aren’t yet.
- **A target and a deadline per device,** from the Blueprint and Apple’s release data, in each device’s local time.
- **Every device in a category with a plain-language diagnosis,** and Inspect for the likely cause on a single device.
- **A dashboard per Blueprint:** progress, history, deadlines per time zone and hardware to replace. The device list and a summary can be exported.
- **Read only:** connects to the Jamf Platform API with read permissions only, and never changes anything in Jamf.
- **Demo Mode** with sample iPads and Macs, to try the app without a Jamf tenant.
