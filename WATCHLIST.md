# Software Update Dashboard: watchlist

What this app is waiting for from Apple or Jamf, or must recheck. Check each item when the vendor ships an update.

- **Status item times (Jamf):** Jamf Pro writes `lastUpdateTime` of DDM status items in the server's local time, without a zone (Jamf's API reference). The app reads them in the connection's server time zone (UTC by default). If Jamf adds a zone, JTKit's `JamfPro.serverDate` already keeps it.
- **Static computer groups (Jamf):** the Jamf Pro API has no member list for a static computer group; the Classic API's `computergroups/id/{id}` is used. Move to the Jamf Pro API when Jamf adds one.
- **Mobile group membership over the Platform API (Jamf):** Jamf's reference documents the full inventory in `v2/mobile-device-groups/…-membership/{id}`, but over the Platform API every field but the ID and name is null (seen on the live tenant, 2026-11-09). JTKit then reads the rest from `v2/mobile-devices/detail`. Recheck when Jamf fixes the membership answer; the extra read can go then. The reference also lists no paging parameters for it there; JTKit sends `page` and `page-size`.
- **Platform device ID (Jamf):** on the live tenant it equals the Jamf Pro management ID (2026-11-09); Jamf doesn't document this, so the app still finds it by serial (`devices/v1/devices`).
- **Declaration Reporting needs a filter (Jamf):** a device's report answers 400 without one; JTKit asks for `active==true,active==false`, then `declarationIdentifier==Blueprint_*`. Not yet confirmed that a device under an update Blueprint returns its declarations (the sampled device had none).
- **Devices without a last contact (Jamf):** Jamf Pro has no `lastContactDate` for some devices that send inventory; the app counts the newer of the two.
- **GDMF (Apple):** Apple's software lookup service isn't documented as an API; its shape was checked live. iOS entries also hold Apple Watch releases (filtered out in JTKit).
- **SOFA (Mac Admins Open Source):** the v2 feeds are used; v1 paths on sofa.macadmins.io are deprecated. SOFA asks for an app-specific User-Agent, which the app sends.
- **Computer time zones (Jamf):** Jamf Pro's computer inventory has no time zone, so a Mac's deadline is shown in its local time without a zone.
