# Software Update Dashboard: watchlist

What this app is waiting for from Apple or Jamf, or must recheck. Check each item when the vendor ships an update.

- **Status item times (Jamf):** Jamf Pro writes `lastUpdateTime` of DDM status items in the server's local time, without a zone (Jamf's API reference). The app reads them in the connection's server time zone (UTC by default). If Jamf adds a zone, JTKit's `JamfPro.serverDate` already keeps it.
- **Static computer groups (Jamf):** the Jamf Pro API has no member list for a static computer group; the Classic API's `computergroups/id/{id}` is used. Move to the Jamf Pro API when Jamf adds one.
- **Mobile group membership over the Platform API (Jamf):** Jamf's reference lists no paging parameters for `v2/mobile-device-groups/…-membership/{id}` on the Platform API; JTKit sends `page` and `page-size`. Recheck that large groups come back complete.
- **Platform device ID (Jamf):** Declaration Reporting is keyed by the Platform API's device ID, which the app finds by serial (`devices/v1/devices`). If Jamf documents that it equals the Jamf Pro management ID, the lookup can go.
- **GDMF (Apple):** Apple's software lookup service isn't documented as an API; its shape was checked live. iOS entries also hold Apple Watch releases (filtered out in JTKit).
- **SOFA (Mac Admins Open Source):** the v2 feeds are used; v1 paths on sofa.macadmins.io are deprecated. SOFA asks for an app-specific User-Agent, which the app sends.
- **Computer time zones (Jamf):** Jamf Pro's computer inventory has no time zone, so a Mac's deadline is shown in its local time without a zone.
