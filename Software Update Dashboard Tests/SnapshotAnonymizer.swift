import CryptoKit
import Foundation

/// Development tool, in the test target only (never in the shipped app):
/// turns what identifies a device, a person or the tenant into stable
/// made-up values before a snapshot is written (`LiveSnapshot`).
///
/// - `token(_:kind:)`: an identifier (serial, name, ID, email) becomes
///   `<Kind>-<8 hex>`, from an HMAC with the snapshot key, so the same
///   device gets the same token in every snapshot taken with that key.
/// - `scrub(_:)`: free text (status item values, error messages, diagnoses)
///   keeps its wording; every identifier seen so far is replaced by its
///   token, and so is anything that looks like an email address, a UUID, a
///   long hex token or a serial number. Web addresses and host names are
///   dropped.
/// - Everything else (models, board IDs, versions, time zones, dates,
///   states, reasons, counts) is written as it is, by the caller.
final class SnapshotAnonymizer {
    private let key: SymmetricKey
    /// Originals seen as identifiers, with their tokens, for free text.
    private var known: [String: String] = [:] {
        didSet { knownPattern = nil }
    }
    /// All of `known` as one pattern, longest first; built again only after a change.
    private var knownPattern: NSRegularExpression?
    /// Free text replacements only for values this long: shorter ones
    /// (Jamf Pro's numbers) would replace parts of versions and dates.
    static let minimumTextLength = 5

    init(key: Data) {
        self.key = SymmetricKey(data: key)
    }

    /// The originals replaced so far, for the check that none is left in
    /// the file: every identifier but device names and places (a device can
    /// be named like its model), and every alias.
    private(set) var originals: Set<String> = []
    /// Device names replaced so far, checked apart (they can equal a model name).
    private(set) var names: Set<String> = []
    /// The kind each original was registered as (“Serial”, “ID”, an alias’s “Label”), for reports without values.
    private(set) var kinds: [String: String] = [:]

    /// A stable token for an identifier; nil for nil or an empty value.
    func token(_ value: String?, kind: String) -> String? {
        token(value, kind: kind, remember: true)
    }

    /// `remember`: also replace it in later free text (an identifier the
    /// caller registers); a value the patterns below find needn't be.
    func token(_ value: String?, kind: String, remember: Bool) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        let mac = HMAC<SHA256>.authenticationCode(for: Data("\(kind)|\(value.lowercased())".utf8), using: key)
        let token = "\(kind)-" + mac.prefix(4).map { String(format: "%02x", $0) }.joined()
        if value.count >= Self.minimumTextLength {
            if remember, known[value.lowercased()] != token { known[value.lowercased()] = token }
            kinds[value] = kind
            switch kind {
            case "Name": names.insert(value)
            case "Place": break
            default: originals.insert(value)
            }
        }
        return token
    }

    /// Which of the replaced values are still in `text` (case-insensitive):
    /// every original, and every device name not part of an allowed text
    /// (a model’s name). Fast on a large file: a value is searched for only
    /// when each of its words is one of the file’s words.
    func leaks(in text: String, allowingNamesIn allowed: [String] = []) -> [String] {
        let lowered = text.lowercased()
        func words(_ value: String) -> [Substring] { value.split { !($0.isLetter || $0.isNumber) } }
        let present = Set(words(lowered))
        let haystack = Array(lowered.utf8)
        func contained(_ value: String) -> Bool {
            let needle = value.lowercased()
            let parts = words(needle)
            guard !parts.isEmpty, parts.allSatisfy(present.contains) else { return false }
            // a byte search (memmem): the file can be tens of megabytes
            let bytes = Array(needle.utf8)
            return haystack.withUnsafeBytes { hay in
                bytes.withUnsafeBytes { memmem(hay.baseAddress, hay.count, $0.baseAddress, $0.count) != nil }
            }
        }
        let names = names.filter { name in !allowed.contains { $0.localizedCaseInsensitiveContains(name) } }
        return (originals.filter(contained) + names.filter(contained)).sorted()
    }

    /// Where a value turns up in a JSON text: the key of the field it is in,
    /// for a report that never shows the value.
    static func field(of value: String, in text: String) -> String {
        guard let found = text.range(of: value, options: .caseInsensitive) else { return "?" }
        // the last `"key":` before it (a regular expression can't search backwards)
        let before = String(text[..<found.lowerBound].suffix(4_000))
        guard let key = before.matches(of: /"([A-Za-z]+)"\s*:/).last else { return "?" }
        return String(key.output.1)
    }

    /// The organisation’s own words, taken at run time from the tenant’s
    /// host names (never written down), shown as “Org” everywhere.
    func organisation(fromHosts hosts: [String]) {
        let generic: Set<String> = ["jamf", "jamfcloud", "jamfpro", "www", "api", "mdm", "com", "net", "org", "be", "nl", "eu", "io", "cloud"]
        for host in hosts {
            for word in host.lowercased().split(separator: ".").map(String.init) where word.count >= 3 && !generic.contains(word) {
                alias(word, as: "Org")
            }
        }
    }

    /// A name shown as a label instead (“Blueprint A”, “Group 1”), also in free text.
    func alias(_ original: String?, as label: String) {
        guard let original = original?.trimmingCharacters(in: .whitespacesAndNewlines), original.count >= 3 else { return }
        known[original.lowercased()] = label
        originals.insert(original)
        kinds[original] = "Label"
    }

    /// Free text with every identifier replaced and every address dropped.
    func scrub(_ text: String?) -> String? {
        guard var text, !text.isEmpty else { return text }
        // emails, then host names first: a name or serial inside one would otherwise be replaced and hide it
        text = replace(Self.email, in: text) { self.token($0, kind: "Email", remember: false) ?? "Email" }
        text = replace(Self.address, in: text) { _ in "[address]" }
        text = replace(Self.host, in: text) { _ in "[host]" }
        // what was seen as an identifier, longest first (a name containing a shorter one), in one pass
        if knownPattern == nil, !known.isEmpty {
            let alternatives = known.keys.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:))
            knownPattern = try? NSRegularExpression(pattern: alternatives.joined(separator: "|"), options: [.caseInsensitive])
        }
        if let knownPattern {
            text = replace(knownPattern, in: text) { self.known[$0.lowercased()] ?? $0 }
        }
        // a Mac's account name in a path (/Users/<account>/…): a person's name, often
        text = replace(Self.homeFolder, in: text) { match in
            let account = String(match.dropFirst("/Users/".count))
            guard account != "Shared", account.range(of: #"^[A-Z][a-z]+-[0-9a-f]{8}$"#, options: .regularExpression) == nil else { return match }
            return "/Users/" + (self.token(account, kind: "User", remember: false) ?? "User")
        }
        text = replace(Self.uuid, in: text) { self.token($0, kind: "ID", remember: false) ?? "ID" }
        text = replace(Self.hex, in: text) { self.token($0, kind: "Token", remember: false) ?? "Token" }
        // a serial number: 10 to 12 capitals and digits, both; board IDs (…AP) stay
        text = replace(Self.serial, in: text) { match in
            match.hasSuffix("AP") ? match : self.token(match, kind: "Serial", remember: false) ?? "Serial"
        }
        return text
    }

    private static func pattern(_ text: String) -> NSRegularExpression {
        do { return try NSRegularExpression(pattern: text) } catch { fatalError("Snapshot pattern: \(error)") }
    }
    private static let email = pattern(#"(?i)[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}"#)
    private static let homeFolder = pattern(#"/Users/[^/,;}\]\s"']+(?=/)"#)
    private static let address = pattern(#"(?i)\b[a-z][a-z0-9+.-]*://[^\s"'<>,;)}\]]+"#)
    /// A host name: labels ending in a common top-level domain, `.local` (a
    /// Mac’s Bonjour name, often its owner’s) or a company network’s.
    private static let host = pattern(#"(?i)\b(?:[a-z0-9_-]+\.)+(?:com|net|org|be|nl|fr|de|eu|uk|io|co|cloud|local|lan|internal|corp|home|intra)\b(?![.-]?[a-z0-9])"#)
    private static let uuid = pattern(#"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"#)
    /// A long hex token; never an Intel Mac’s board ID (`Mac-` and 16 hex digits), which stays.
    private static let hex = pattern(#"(?i)(?<!Mac-)\b[0-9a-f]{16,}\b"#)
    private static let serial = pattern(#"\b(?=[A-Z0-9]*[A-Z])(?=[A-Z0-9]*[0-9])[A-Z0-9]{10,12}\b"#)

    private func replace(_ regex: NSRegularExpression, in text: String, with replacement: (String) -> String) -> String {
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: replacement(String(result[range])))
        }
        return result
    }
}
