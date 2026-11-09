import Foundation
import JTKit

/// A saved Jamf Platform API connection, with the time zone of the Jamf Pro
/// server behind it: Jamf Pro writes the times of DDM status items in its own
/// local time, without a zone.
nonisolated struct AppConnection: ConnectionRecord, Codable, Hashable {
    var connection: Connection
    /// An IANA name, e.g. `UTC` or `Europe/Brussels`.
    var serverTimeZone: String

    static let defaultServerTimeZone = "UTC"

    var id: UUID { connection.id }

    init(connection: Connection, serverTimeZone: String = AppConnection.defaultServerTimeZone) {
        self.connection = connection
        self.serverTimeZone = serverTimeZone
    }

    /// The server’s time zone; UTC when the saved name isn’t one.
    var timeZone: TimeZone {
        TimeZone(identifier: serverTimeZone) ?? TimeZone(identifier: Self.defaultServerTimeZone) ?? .gmt
    }

    private enum CodingKeys: String, CodingKey {
        case connection, serverTimeZone
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        connection = try container.decode(Connection.self, forKey: .connection)
        serverTimeZone = try container.decodeIfPresent(String.self, forKey: .serverTimeZone) ?? Self.defaultServerTimeZone
    }
}
