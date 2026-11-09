import Foundation
import JTKit

/// One device as the classifier gets it: its inventory from the group’s
/// membership, and its DDM status report.
nonisolated struct DeviceInput: Sendable, Hashable {
    var member: JamfPro.GroupMember
    /// Nil when Jamf Pro has no report for it (404) or it couldn’t be read.
    var status: JamfPro.SoftwareUpdateStatus?
    /// Why the report couldn’t be read (anything but “none yet”), e.g. a
    /// missing permission.
    var statusProblem: String?

    init(member: JamfPro.GroupMember, status: JamfPro.SoftwareUpdateStatus? = nil, statusProblem: String? = nil) {
        self.member = member
        self.status = status
        self.statusProblem = statusProblem
    }
}

/// What classification needs besides the devices.
nonisolated struct ClassificationContext: Sendable {
    /// The version the Blueprint asks for; nil when unknown (then nothing is on target).
    var target: OSVersion?
    /// When the update started (the Blueprint’s last change): status
    /// reports and errors before it don’t count. Nil: every report counts.
    var since: Date?
    /// The zone Jamf Pro writes status item times in.
    var serverTimeZone: TimeZone
    var now: Date
    /// No contact for longer than this: offline.
    var staleDays: Int
    /// Whether a device can run a major: true or false when Apple’s release
    /// data knows its model or board ID, nil when it doesn’t.
    var supports: @Sendable (_ model: String?, _ boardID: String?, _ major: Int) -> Bool?
    /// Below this major, a device that hasn’t started is pointed at its
    /// hardware (the oldest major Apple still updates); nil: never.
    var oldestMaintainedMajor: Int?

    init(target: OSVersion?, since: Date? = nil, serverTimeZone: TimeZone = .gmt, now: Date = Date(), staleDays: Int = 30,
         supports: @escaping @Sendable (_ model: String?, _ boardID: String?, _ major: Int) -> Bool? = { _, _, _ in nil },
         oldestMaintainedMajor: Int? = nil) {
        self.target = target
        self.since = since
        self.serverTimeZone = serverTimeZone
        self.now = now
        self.staleDays = staleDays
        self.supports = supports
        self.oldestMaintainedMajor = oldestMaintainedMajor
    }

    /// The context Apple’s release data gives for a platform.
    init(target: OSVersion?, since: Date?, serverTimeZone: TimeZone, now: Date, staleDays: Int = 30,
         catalog: AppleReleases.Catalog?, platform: AppleReleases.Platform) {
        self.init(target: target, since: since, serverTimeZone: serverTimeZone, now: now, staleDays: staleDays,
                  supports: { model, board, major in catalog?.supports(model: model, boardID: board, major: major, platform) },
                  // Apple updates the current major and the two before it
                  oldestMaintainedMajor: catalog.flatMap { $0.majors(platform).prefix(3).last })
    }
}

/// One classified device: a row of the device list, the CSV and the history.
nonisolated struct DeviceStatus: Sendable, Hashable, Identifiable, Codable {
    /// Jamf Pro’s ID of the device.
    var id: String
    var isComputer: Bool
    var name: String
    var serial: String
    /// The marketing name, e.g. “iPad Air (5th generation)”.
    var model: String
    /// The model identifier, or the board ID the status report names when
    /// the inventory has none.
    var modelIdentifier: String
    var inventoryOS: String?
    var reportedOS: String?
    var installState: String?
    var pendingVersion: String?
    var failureCount: Int?
    /// The failure reason, shortened.
    var error: String
    var errorTime: String?
    /// Whether the error is from after the update started; nil without one.
    var errorSinceUpdate: Bool?
    var passcodePresent: Bool?
    var lastContact: Date?
    /// The newest software update or OS item of the status report.
    var statusUpdated: Date?
    /// The device’s own time zone (mobile devices only).
    var timeZone: String?
    var managementID: String?
    var category: StatusCategory
    var diagnosis: String
    /// Why the status report couldn’t be read, if it couldn’t.
    var statusProblem: String?

    /// The version the device reports, else the one in its inventory.
    var currentOS: String { reportedOS ?? inventoryOS ?? "" }

    /// iPadOS, iOS or macOS.
    var osName: String { Classifier.osName(isComputer: isComputer, modelIdentifier: modelIdentifier) }

    /// The diagnoses that need someone to look (summary, Inspect’s default selection).
    static let attentionPattern = "[Ii]nstall blocked|^Update failed|^Download problem|^No update offered|^Other error|^Online, update not started|^On [A-Za-z]+ [0-9]+: check"

    var needsAttention: Bool { diagnosis.range(of: Self.attentionPattern, options: .regularExpression) != nil }

    /// The CSV’s columns, in order.
    static let csvColumns = ["jamf_pro_id", "name", "serial", "model", "model_id", "inventory_os", "reported_os",
                             "install_state", "pending_version", "category", "diagnosis", "error", "error_time",
                             "error_since_update", "passcode_present", "last_contact", "status_updated", "time_zone"]

    var csvLine: String {
        func date(_ value: Date?) -> String { value.map { $0.formatted(.iso8601) } ?? "" }
        func flag(_ value: Bool?) -> String { value.map { $0 ? "yes" : "no" } ?? "" }
        return CSV.line([id, name, serial, model, modelIdentifier, inventoryOS ?? "", reportedOS ?? "", installState ?? "",
                         pendingVersion ?? "", category.rawValue, diagnosis, error, errorTime ?? "", flag(errorSinceUpdate),
                         passcodePresent.map { $0 ? "true" : "false" } ?? "", date(lastContact), date(statusUpdated),
                         timeZone ?? ""])
    }
}

/// Joins inventory and status reports, puts every device in a category
/// against the target version and adds a plain-language diagnosis.
///
/// Devices only send status items when something changes, so an item can be
/// weeks old. Only software update activity and errors reported after the
/// update started count.
nonisolated enum Classifier {
    static func classify(_ inputs: [DeviceInput], context: ClassificationContext) -> [DeviceStatus] {
        inputs.map { classify($0, context: context) }
    }

    static func classify(_ input: DeviceInput, context ctx: ClassificationContext) -> DeviceStatus {
        let member = input.member
        let status = input.status
        let target = ctx.target
        let ddmOS = status?.osVersion
        let state = status?.installState
        let pending = status?.pendingVersion?.osVersion
        let failTime = status?.failure?.timestamp
        let failAt = failTime.flatMap { JamfPro.serverDate($0, timeZone: ctx.serverTimeZone) }
        let failedSince = failAt.map { at in ctx.since.map { at >= $0 } ?? true } ?? false
        let updated = status?.newestUpdate.flatMap { JamfPro.serverDate($0, timeZone: ctx.serverTimeZone) }
        let fresh = ctx.since.map { since in updated.map { $0 >= since } ?? false } ?? true
        let ours = pending.flatMap(OSVersion.init).map { version in target.map { !(version < $0) } ?? true } ?? true
        let osText = ddmOS ?? member.osVersion ?? ""
        let os = OSVersion(osText)
        let modelID = member.modelIdentifier.flatMap { $0.isEmpty ? nil : $0 }
        let unsupportedHardware = target.map { ctx.supports(modelID ?? status?.modelIdentifier, status?.deviceID, $0.major) == false } ?? false
        let busy = state?.isBusy ?? false
        let isFailed = state == .failed
        let itemCount = status?.itemCount ?? 0
        let stale = member.lastContact.map { ctx.now.timeIntervalSince($0) > Double(ctx.staleDays) * 86_400 } ?? true

        let category: StatusCategory
        if let target, let os, !(os < target) { category = .onTarget }
        else if itemCount == 0 && ddmOS == nil { category = stale ? .offline : .noReport }
        else if unsupportedHardware, let os, let target, os.major < target.major { category = .unsupported }
        else if stale { category = .offline }
        else if !fresh { category = .noActivity }
        else if (isFailed || busy) && !ours { category = .otherUpdate }
        else if isFailed { category = .failed }
        else if busy { category = .inProgress }
        else if failedSince && ours { category = .failed }
        else { category = .notStarted }

        let error = shortError(status?.failure?.reason)
        let errorNow = failedSince ? error : ""
        let blocker: String
        if matches(errorNow, "Passcode|Keybag") { blocker = "the passcode" }
        else if matches(errorNow, "[Bb]attery") { blocker = "low battery (installs when charging)" }
        else if matches(errorNow, "MediaPlaying") { blocker = "media playing" }
        else if matches(errorNow, "NetworkRequired") { blocker = "no network" }
        else { blocker = "" }
        let via = category == .otherUpdate ? pending.map { " (intermediate version \($0))" } ?? "" : ""
        let osName = osName(isComputer: member.kind == .computer, modelIdentifier: modelID ?? "")

        let diagnosis: String
        switch true {
        case category == .onTarget: diagnosis = "On target"
        case category == .unsupported:
            diagnosis = "Hardware can’t run \(osName) \(target?.major ?? 0) (stays on its last supported version)"
        case category == .offline: diagnosis = "Offline: no contact for more than \(ctx.staleDays) days"
        case category == .noActivity: diagnosis = "No report since the update started (switched off or not synced yet)"
        case category == .noReport && input.statusProblem != nil: diagnosis = "Update status couldn’t be read"
        case category == .noReport: diagnosis = "No update status available"
        case state == .installing: diagnosis = "Installing now\(via)"
        case state == .prepared && !blocker.isEmpty: diagnosis = "Downloaded\(via), install blocked by \(blocker)"
        case state == .prepared: diagnosis = "Downloaded\(via), installs at the deadline"
        case busy: diagnosis = "Downloading\(via)"
        case !blocker.isEmpty: diagnosis = "Install blocked by \(blocker)"
        case isFailed && errorNow.isEmpty: diagnosis = "Update failed (no error details)"
        case matches(errorNow, "extractor|catalog|[Dd]ownload|[Tt]imed ?[Oo]ut|XPC|digested|[Nn]etwork"):
            diagnosis = "Download problem (device retries)"
        case errorNow == "No update found" || matches(errorNow, "NoUpdateFound|no update found"):
            diagnosis = "No update offered (check deferrals and compatibility)"
        case !errorNow.isEmpty: diagnosis = "Other error: \(errorNow)"
        case os != nil && ctx.oldestMaintainedMajor.map { os!.major < $0 } == true:
            diagnosis = "On \(osName) \(os!.major): check if the hardware supports a newer \(osName)"
        default: diagnosis = "Online, update not started (no error)"
        }

        return DeviceStatus(
            id: member.id, isComputer: member.kind == .computer, name: member.name ?? "", serial: member.serialNumber ?? "",
            model: member.model ?? "", modelIdentifier: modelID ?? status?.modelIdentifier ?? status?.deviceID ?? "",
            inventoryOS: member.osVersion, reportedOS: ddmOS, installState: state?.rawValue, pendingVersion: pending,
            failureCount: status?.failure?.count, error: error, errorTime: failTime,
            errorSinceUpdate: failTime == nil ? nil : failedSince, passcodePresent: status?.passcodePresent ?? member.passcodePresent,
            lastContact: member.lastContact, statusUpdated: updated, timeZone: member.timeZone, managementID: member.managementID,
            category: category, diagnosis: diagnosis, statusProblem: input.statusProblem)
    }

    /// iPadOS for an iPad, iOS for an iPhone, macOS for a Mac.
    static func osName(isComputer: Bool, modelIdentifier: String) -> String {
        if isComputer || modelIdentifier.hasPrefix("Mac") { return "macOS" }
        return modelIdentifier.hasPrefix("iPad") ? "iPadOS" : "iOS"
    }

    /// A failure reason, shortened: the last `Code=… "text"` part of an
    /// NSError description, without its asset or catalog download note;
    /// Apple’s `(null)` means no update was found.
    static func shortError(_ reason: String?) -> String {
        guard let text = reason, !text.isEmpty else { return "" }
        var result = text
        let codes = text.matches(of: /Code=(-?[0-9]+) "([^"]*)"/)
        if let last = codes.last { result = String(last.output.2) }
        if let note = result.firstMatch(of: #/ \((Asset|Catalog) download for [^)]*\)/#) {
            result.removeSubrange(note.range)
        }
        return result == "(null)" ? "No update found" : result
    }

    static func matches(_ text: String, _ pattern: String) -> Bool {
        !text.isEmpty && text.range(of: pattern, options: .regularExpression) != nil
    }
}

/// CSV as spreadsheets read it: a field with a comma, quote or line break
/// is quoted, with its quotes doubled.
nonisolated enum CSV {
    static func line(_ fields: [String]) -> String {
        fields.map { field in
            field.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline })
                ? "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : field
        }.joined(separator: ",")
    }

    static func document(header: [String], lines: [String]) -> String {
        ([line(header)] + lines).joined(separator: "\n") + "\n"
    }
}
