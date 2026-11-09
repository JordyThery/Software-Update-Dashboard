import Foundation
import JTKit

/// What the About window shows (JTKit’s `AboutWindow`).
extension AboutConfiguration {
    static let softwareUpdateDashboard = AboutConfiguration(
        appName: "Software Update Dashboard",
        copyright: AboutCopyright(year: "2026", holder: "Jordy Thery"),
        author: "Created by Jordy Thery",
        summary: "Shows, for a group of devices, whether they are on the OS version their Blueprint’s software update asks for, and if not, why not. It only reads from Jamf and never changes anything.",
        links: [
            AboutLink("github.com/JordyThery/Software-Update-Dashboard", address: "https://github.com/JordyThery/Software-Update-Dashboard"),
            AboutLink("Release data: SOFA by Mac Admins Open Source", address: "https://sofa.macadmins.io"),
        ].compactMap { $0 }
    )
}

extension UpdateConfiguration {
    static let softwareUpdateDashboard = UpdateConfiguration(
        owner: "JordyThery", repository: "Software-Update-Dashboard", appName: "Software Update Dashboard")
}
