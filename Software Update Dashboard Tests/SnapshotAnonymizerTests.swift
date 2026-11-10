import Foundation
import Testing
@testable import Software_Update_Dashboard

/// The snapshot tool's anonymizer (development tool, test target only).
/// Made-up values only.
@Suite("Snapshot tool: anonymizing")
@MainActor
struct SnapshotAnonymizerTests {
    static let key = Data((0..<32).map { UInt8($0) })

    @Test("The same value always gets the same token, with the same key; another key gives another")
    func stable() {
        let one = SnapshotAnonymizer(key: Self.key), two = SnapshotAnonymizer(key: Self.key)
        #expect(one.token("ZZTEST0001", kind: "Serial") == two.token("zztest0001", kind: "Serial"))
        #expect(one.token("ZZTEST0001", kind: "Serial")?.hasPrefix("Serial-") == true)
        #expect(one.token("ZZTEST0001", kind: "Serial") != one.token("ZZTEST0002", kind: "Serial"))
        #expect(SnapshotAnonymizer(key: Data(repeating: 7, count: 32)).token("ZZTEST0001", kind: "Serial")
                != one.token("ZZTEST0001", kind: "Serial"))
        #expect(one.token(nil, kind: "Serial") == nil && one.token(" ", kind: "Serial") == nil)
    }

    @Test("Free text keeps its wording; identifiers, emails, UUIDs, tokens and serials are replaced, addresses dropped")
    func scrub() throws {
        let anonymizer = SnapshotAnonymizer(key: Self.key)
        let name = try #require(anonymizer.token("Test Person’s iPad", kind: "Name"))
        anonymizer.alias("Example Update Blueprint", as: "Blueprint A")
        let text = "Error.ConfigurationFailed: Test Person’s iPad (ZZTESTX9Q12) at https://example.jamfcloud.com/x, "
            + "mail someone@example.com, host tenant.example.be, device 6a2f0000-1111-4000-8000-00000000c0de, "
            + "token 0123456789abcdef0123, Example Update Blueprint, macOS 26.7.2 (25G332) on J457AP and X86LEGACYAP, 2026-11-10T12:00:00"
        let scrubbed = try #require(anonymizer.scrub(text))
        #expect(scrubbed.hasPrefix("Error.ConfigurationFailed: \(name) (Serial-"))
        for gone in ["Test Person", "ZZTESTX9Q12", "example.jamfcloud.com", "someone@", "tenant.example.be",
                     "6a2f0000-1111", "0123456789abcdef0123", "Example Update"] {
            #expect(!scrubbed.contains(gone), "\(gone)")
        }
        #expect(scrubbed.contains("[address]") && scrubbed.contains("[host]") && scrubbed.contains("Email-")
                && scrubbed.contains("ID-") && scrubbed.contains("Token-") && scrubbed.contains("Blueprint A"))
        // what stays: versions, builds, board IDs, dates
        // a Mac's account name in a path; /Users/Shared stays
        let path = anonymizer.scrub("{path=/Users/someone/Library/LaunchAgents/com.example.agent.plist}, /Users/Shared/x") ?? ""
        #expect(!path.contains("someone") && path.contains("/Users/User-") && path.contains("/Users/Shared/x"))
        #expect(anonymizer.originals.contains("someone"))
        // hosts that hold a name, a Bonjour name, and the organisation's own words
        let other = SnapshotAnonymizer(key: Self.key)
        _ = other.token("Some Laptop", kind: "Name")
        other.organisation(fromHosts: ["mdm.example-org.be", "jamf.examplecorp.com"])
        let hosts = other.scrub("server=some-laptop.example-org.be, bonjour Somebodys-MacBook.local, ntp time.example.org, "
                                + "agent com.examplecorp.helper.plist, app /Applications/ExampleCorp Tools.app, version 26.7.2") ?? ""
        #expect(!hosts.lowercased().contains("example") && !hosts.contains("Somebodys") && !hosts.contains("some-laptop"))
        #expect(hosts.contains("com.Org.helper.plist") && hosts.contains("/Applications/Org Tools.app") && hosts.contains("version 26.7.2"))
        #expect(hosts.components(separatedBy: "[host]").count - 1 == 3)
        // an Intel Mac's board ID is a board ID, not a token
        #expect(anonymizer.scrub("board Mac-06F11F11946D27C5") == "board Mac-06F11F11946D27C5")
        for kept in ["macOS 26.7.2 (25G332)", "J457AP", "X86LEGACYAP", "2026-11-10T12:00:00"] {
            #expect(scrubbed.contains(kept), "\(kept)")
        }
        // the leak check knows what it replaced
        #expect(anonymizer.originals.contains("ZZTESTX9Q12") && anonymizer.originals.contains("Example Update Blueprint"))
        #expect(anonymizer.names.contains("Test Person’s iPad"))
        #expect(anonymizer.leaks(in: scrubbed).isEmpty)
        #expect(anonymizer.leaks(in: "left: zztestx9q12 and Test Person’s iPad") == ["Test Person’s iPad", "ZZTESTX9Q12"])
        // a device named like its model isn't a leak in the model's field
        _ = anonymizer.token("MacBook Air", kind: "Name")
        #expect(anonymizer.leaks(in: "MacBook Air (M2)", allowingNamesIn: ["MacBook Air (M2)"]).isEmpty)
        #expect(SnapshotAnonymizer.field(of: "zz9", in: #"{"a": "x", "b": {"c": "zz9"}}"#) == "c")
    }

    @Test("Short values (Jamf Pro’s numbers) are never replaced inside other text")
    func shortValues() {
        let anonymizer = SnapshotAnonymizer(key: Self.key)
        _ = anonymizer.token("26", kind: "JamfID")
        #expect(anonymizer.scrub("macOS 26.7.2, 2026-11-26") == "macOS 26.7.2, 2026-11-26")
    }

    @Test("Snapshot labels and key: A to Z then AA; the key must be hex of at least 16 bytes")
    func helpers() {
        #expect(LiveSnapshot.letters(0) == "A" && LiveSnapshot.letters(25) == "Z" && LiveSnapshot.letters(26) == "AA")
        #expect(LiveSnapshot.data(hex: String(repeating: "ab", count: 32))?.count == 32)
        #expect(LiveSnapshot.data(hex: "abcd") == nil && LiveSnapshot.data(hex: String(repeating: "zz", count: 32)) == nil)
    }
}
