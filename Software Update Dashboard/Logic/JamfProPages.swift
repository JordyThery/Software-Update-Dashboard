import Foundation
import JTKit

/// Pages in the Jamf Pro web interface for Open in Jamf Pro, from the
/// connection’s Jamf Pro Web Address (Settings › Connections): the Platform
/// API doesn’t give it without another permission. JTKit’s links open
/// device pages read-only. Only the browser opens them; the app sends nothing.
nonisolated enum JamfProPages {
    /// Opening more devices than this at once asks first.
    static let askAbove = 10
    /// Demo Mode’s address: on `.demo.invalid`, so it names no real server.
    static let demoAddress = "https://contoso.demo.invalid"
    /// Why Open in Jamf Pro is off.
    static let noAddress = "Add the connection’s Jamf Pro web address in Settings › Connections to open pages in Jamf Pro."

    /// The device’s page, by its Jamf Pro number and kind; nil without an address.
    static func device(_ device: DeviceStatus, base: String?) -> URL? {
        guard let base, !base.isEmpty else { return nil }
        return device.isComputer ? JamfWebLink.computer(id: device.jamfID, base: base)
            : JamfWebLink.mobileDevice(id: device.jamfID, base: base)
    }

    /// The Blueprint’s page; nil without an address.
    static func blueprint(id: String, base: String?) -> URL? {
        guard let base, !base.isEmpty else { return nil }
        return JamfWebLink.blueprint(id: id, base: base)
    }
}
