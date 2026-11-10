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
    /// The Platform API’s device ID, found by serial number; nil when the
    /// serial isn’t in the Platform device list.
    var platformDeviceID: String?

    init(member: JamfPro.GroupMember, status: JamfPro.SoftwareUpdateStatus? = nil, statusProblem: String? = nil,
         platformDeviceID: String? = nil) {
        self.member = member
        self.status = status
        self.statusProblem = statusProblem
        self.platformDeviceID = platformDeviceID
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
    /// No release applies to this device’s hardware at all (the target rules
    /// found none): it is unsupported, whatever it reports.
    var noApplicableRelease = false

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
    /// Jamf Pro’s number of the device, unique only within its kind (`id` adds the kind).
    var jamfID: String
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
    /// The device’s own target and why (nil in history saved before targets per device).
    var targetVersion: String?
    var targetReason: String?
    /// Apple’s release date of the target, a day (shown without a time).
    var targetReleased: Date?
    /// Reports and errors before this didn’t count.
    var activityFrom: Date?
    /// The deadline in the device’s local time.
    var deadlineLocal: String?
    var pastDeadline: Bool?
    /// Measured against the newest release its model can run: a newer major exists it can’t.
    var limitedByHardware: Bool?
    /// The target is the version the device reports pending from a declaration.
    var targetFromDevice: Bool?
    /// Then: what the Blueprint’s rule gives, and whether it differs.
    var ruleTarget: String?
    var ruleReason: String?
    var targetDiffersFromRule: Bool?
    /// The deadline as a moment and its offset from UTC, when the device reported one.
    var deadlineDate: Date?
    var deadlineOffset: Int?
    /// Where the target comes from, e.g. “27.2, sent by Jamf, matches the Blueprint’s rule”.
    var targetSource: String?
    /// Where the deadline comes from, e.g. “from Apple’s posting date”.
    var deadlineSource: String?
    /// A deadline the device reported before the Blueprint’s last change
    /// (or Apple’s posting of the version): shown, not used. A moment, or
    /// the device’s local date-time when the report gave no offset.
    var staleReportedDeadline: Date?
    var staleReportedLocal: String?
    var staleSince: Date?
    var staleReason: StaleReason?
    /// `softwareupdate.device-id` from the status report.
    var boardID: String?
    /// A Mac’s bootstrap token in Jamf Pro: `ESCROWED`, `NOT_ESCROWED`, `NOT_SUPPORTED`.
    var bootstrapToken: String?
    /// This Blueprint’s earlier step, still pending: shown, not counted (`DeviceTarget`).
    var earlierStepVersion: String?
    var earlierStepDeadline: Date?
    var earlierStepLocal: String?
    /// The step’s own deadline has passed: it is the target again, late.
    var earlierStepLapsed: Bool?
    /// The target pending with the deadline of this Blueprint’s earlier step: shown, not counted (`DeviceTarget`).
    var carriedStepVersion: String?
    var carriedDeadline: Date?
    var carriedDeadlineLocal: String?
    /// A Rapid Security Response the device runs (`(a)`), and its build.
    var rapidSecurityResponse: String?
    var supplementalBuild: String?
    /// The beta program the device is enrolled in, if any.
    var betaEnrollment: String?
    /// Why the pending update was started: `declaration`, `mdm`, …, comma-separated.
    var installReason: String?
    /// A Mac’s FileVault as Jamf Pro reports its boot volume: `ENCRYPTED`, `UNENCRYPTED`, …
    var fileVault: String?
    /// Battery health from the status report, else the inventory.
    var batteryHealth: String?
    /// The Blueprint’s version ranges for this hardware, none of which
    /// covers the version the device runs (“macOS 27.0 to 27.0.1”).
    var notCoveredBy: String?
    /// One of the Blueprint’s current declarations covers its version, but
    /// the device hasn’t fetched it; its own report is from `notFetchedSince`.
    var notFetched: Bool?
    var notFetchedSince: Date?
    /// The refresh measured the device against the Blueprint’s current
    /// declarations (Blueprint health could be read).
    var declarationsChecked: Bool?
    /// Readiness (`ReadinessCheck`): from the inventory, and whether Jamf Pro
    /// has no status report of the device at all.
    var supervised: Bool?
    var ddmEnabled: Bool?
    var neverReported: Bool?
    /// An iPhone or iPad enrolled with User Enrollment (Jamf Pro’s inventory).
    var userEnrollment: Bool?

    /// The device by kind and number: a Mac and an iPad can share a number.
    var id: String { "\(isComputer ? "computer" : "mobileDevice")/\(jamfID)" }

    enum CodingKeys: String, CodingKey {
        case jamfID = "id"
        case isComputer
        case name
        case serial
        case model
        case modelIdentifier
        case inventoryOS
        case reportedOS
        case installState
        case pendingVersion
        case failureCount
        case error
        case errorTime
        case errorSinceUpdate
        case passcodePresent
        case lastContact
        case statusUpdated
        case timeZone
        case managementID
        case category
        case diagnosis
        case statusProblem
        case targetVersion
        case targetReason
        case targetReleased
        case activityFrom
        case deadlineLocal
        case pastDeadline
        case limitedByHardware
        case targetFromDevice
        case ruleTarget
        case ruleReason
        case targetDiffersFromRule
        case deadlineDate
        case deadlineOffset
        case targetSource
        case deadlineSource
        case staleReportedDeadline
        case staleReportedLocal
        case staleSince
        case staleReason
        case boardID
        case bootstrapToken
        case earlierStepVersion
        case earlierStepDeadline
        case earlierStepLocal
        case earlierStepLapsed
        case carriedStepVersion
        case carriedDeadline
        case carriedDeadlineLocal
        case rapidSecurityResponse
        case supplementalBuild
        case betaEnrollment
        case installReason
        case fileVault
        case batteryHealth
        case notCoveredBy
        case notFetched
        case notFetchedSince
        case declarationsChecked
        case supervised
        case ddmEnabled
        case neverReported
        case userEnrollment
    }

    /// The newer of the version the device reports and the one in its
    /// inventory: a device that installed may not have reported it yet.
    var currentOS: String { Classifier.newer(reportedOS, inventoryOS) ?? "" }

    /// The deadline as a moment: reported, or the local deadline in the
    /// device’s zone (this Mac’s for a device without one, as Macs).
    var deadlineMoment: Date? {
        deadlineDate ?? TargetRules.deadlineDate(deadlineLocal, timeZone: timeZone ?? TimeZone.current.identifier)
    }

    /// Past the deadline by more than an install gets (`installGrace`): a
    /// downloaded update that still hasn’t installed is stuck. Without a
    /// moment to measure from, past is past. A late earlier step is past
    /// its own deadline by the grace already.
    func pastDeadlineByGrace(now: Date) -> Bool {
        if earlierStepLapsed == true { return true }
        return pastDeadline == true && (deadlineMoment.map { now >= $0.addingTimeInterval(TargetRules.installGrace) } ?? true)
    }

    /// iPadOS, iOS or macOS.
    var osName: String { Classifier.osName(isComputer: isComputer, modelIdentifier: modelIdentifier) }

    /// The diagnoses that need someone to look (summary, Inspect’s default selection).
    static let attentionPattern = "^Downloaded.*not installed after|downloaded but not installed after|[Ii]nstall blocked|^Update failed|^Download problem|^No update offered|^Other error|^Online, update not started|^On [A-Za-z]+ [0-9]+: check|^Installing .*for more than|^Jamf’s update doesn’t cover|^Hasn’t fetched Jamf’s|^Update declaration (failed|invalid)"

    var needsAttention: Bool { diagnosis.range(of: Self.attentionPattern, options: .regularExpression) != nil }

    /// The CSV’s columns, in order.
    static let csvColumns = ["jamf_pro_id", "kind", "name", "serial", "model", "model_id", "inventory_os", "reported_os",
                             "target", "deadline", "deadline_source", "past_deadline", "install_state", "pending_version", "category",
                             "diagnosis", "error", "error_time", "error_since_update", "passcode_present", "last_contact",
                             "status_updated", "time_zone", "rapid_security_response", "beta_enrollment", "install_reason",
                             "failure_count", "filevault", "battery_health"]

    var csvLine: String {
        func date(_ value: Date?) -> String { value.map { $0.formatted(.iso8601) } ?? "" }
        func flag(_ value: Bool?) -> String { value.map { $0 ? "yes" : "no" } ?? "" }
        return CSV.line([jamfID, isComputer ? "computer" : "mobile device", name, serial, model, modelIdentifier,
                         inventoryOS ?? "", reportedOS ?? "", targetVersion ?? "",
                         // a reported deadline as a moment in UTC (with its Z), a computed one in the device's local time
                         deadlineDate.map(date) ?? deadlineLocal ?? "", deadlineSource ?? "", flag(pastDeadline),
                         installState ?? "",
                         pendingVersion ?? "", category.rawValue, diagnosis, error, errorTime ?? "", flag(errorSinceUpdate),
                         passcodePresent.map { $0 ? "true" : "false" } ?? "", date(lastContact), date(statusUpdated),
                         timeZone ?? "", rapidSecurityResponse ?? "", betaEnrollment ?? "", installReason ?? "",
                         failureCount.map(String.init) ?? "", fileVault ?? "", batteryHealth ?? ""])
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
        let pending = status?.pendingVersion?.osVersion
        // the newer of what the device reports and its inventory
        let osText = newer(ddmOS, member.osVersion) ?? ""
        let os = OSVersion(osText)
        // an install state for a version the device already runs is left over
        // from that install: not busy, not failed
        let pendingIsNewer = pending.flatMap(OSVersion.init).map { version in os.map { version > $0 } ?? true } ?? true
        let state = pendingIsNewer ? status?.installState : nil
        let failTime = status?.failure?.timestamp
        let failAt = failTime.flatMap { JamfPro.serverDate($0, timeZone: ctx.serverTimeZone) }
        let failedSince = failAt.map { at in ctx.since.map { at >= $0 } ?? true } ?? false
        let updated = status?.newestUpdate.flatMap { JamfPro.serverDate($0, timeZone: ctx.serverTimeZone) }
        let fresh = ctx.since.map { since in updated.map { $0 >= since } ?? false } ?? true
        let ours = pending.flatMap(OSVersion.init).map { version in target.map { !(version < $0) } ?? true } ?? true
        let modelID = member.modelIdentifier.flatMap { $0.isEmpty ? nil : $0 }
        let unsupportedHardware = target.map { ctx.supports(modelID ?? status?.modelIdentifier, status?.deviceID, $0.major) == false } ?? false
        let busy = state?.isBusy ?? false
        let isFailed = state == .failed
        let itemCount = status?.itemCount ?? 0
        let stale = member.lastSeen.map { ctx.now.timeIntervalSince($0) > Double(ctx.staleDays) * 86_400 } ?? true
        // installing for hours: with contact since, the device checks in
        // but sends no new status; without, it may be asleep
        let installingLong = state == .installing && updated.map { ctx.now.timeIntervalSince($0) > TargetRules.longInstall } == true
        let contactSince = member.lastSeen.map { seen in
            updated.map { seen >= $0.addingTimeInterval(TargetRules.laterContact) } ?? false
        } ?? false

        let category: StatusCategory
        if let target, let os, !(os < target) { category = .onTarget }
        else if itemCount == 0 && ddmOS == nil { category = stale ? .offline : .noReport }
        else if ctx.noApplicableRelease { category = .unsupported }
        else if unsupportedHardware, let os, let target, os.major < target.major { category = .unsupported }
        else if stale { category = .offline }
        else if !fresh { category = .noActivity }
        else if busy && !ours { category = .otherUpdate }
        else if busy { category = .inProgress }
        // update failures since the update started and nothing in progress: failed,
        // also for another version pending (a count of 0 is no failure)
        else if isFailed || (failedSince && status?.failure?.count != 0) { category = .failed }
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
        case category == .unsupported && target == nil:
            diagnosis = "No \(osName) release this hardware can run"
        case category == .unsupported:
            diagnosis = "Hardware can’t run \(osName) \(target?.major ?? 0) (stays on its last supported version)"
        case category == .offline: diagnosis = "Offline: no contact for more than \(ctx.staleDays) days"
        case category == .noActivity: diagnosis = "No report since the update started (switched off or not synced yet)"
        case category == .noReport && input.statusProblem != nil: diagnosis = "Update status couldn’t be read"
        case category == .noReport: diagnosis = "No update status available"
        case state == .installing && installingLong && contactSince:
            diagnosis = "Installing \(pending.map { "\($0) " } ?? "")for more than \(Int(TargetRules.longInstall / 3_600)) hours; "
                + "the device checks in but hasn’t reported a new status"
        case state == .installing && installingLong: diagnosis = "Installing\(via), no contact since it started"
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
        // an error from before the update started doesn't count, but is there
        default: diagnosis = error.isEmpty ? "Online, update not started (no error)"
            : "Online, update not started (no error since the update started)"
        }

        return DeviceStatus(
            jamfID: member.id, isComputer: member.kind == .computer, name: member.name ?? "", serial: member.serialNumber ?? "",
            model: member.model ?? "", modelIdentifier: modelID ?? status?.modelIdentifier ?? status?.deviceID ?? "",
            inventoryOS: member.osVersion, reportedOS: ddmOS, installState: state?.rawValue, pendingVersion: pending,
            failureCount: status?.failure?.count, error: error, errorTime: failTime,
            errorSinceUpdate: failTime == nil ? nil : failedSince, passcodePresent: status?.passcodePresent ?? member.passcodePresent,
            lastContact: member.lastSeen, statusUpdated: updated, timeZone: member.timeZone, managementID: member.managementID,
            category: category, diagnosis: diagnosis, statusProblem: input.statusProblem, boardID: status?.deviceID,
            bootstrapToken: member.bootstrapTokenEscrowedStatus,
            rapidSecurityResponse: status?.supplementalExtraVersion ?? member.osRapidSecurityResponse,
            supplementalBuild: status?.supplementalBuild ?? member.osSupplementalBuild,
            betaEnrollment: status?.betaEnrollment.flatMap(DeviceDetailText.betaProgram),
            installReason: status.flatMap { $0.installReasons.isEmpty ? nil : $0.installReasons.joined(separator: ", ") },
            fileVault: member.diskEncryption?.bootPartitionFileVault2State,
            batteryHealth: status?.batteryHealth ?? member.batteryHealth,
            supervised: member.supervised, ddmEnabled: member.ddmEnabled,
            // no report at all (none, or one without a single item); a report that couldn't be read isn't that
            neverReported: input.statusProblem == nil && (status.map { $0.itemCount == 0 && $0.osVersion == nil } ?? true),
            userEnrollment: member.kind == .mobileDevice ? member.isUserEnrollment : nil)
    }

    /// One device measured against its own target (`TargetRules`): its
    /// target, the start of its activity, and its deadline.
    static func classify(_ input: DeviceInput, target: DeviceTarget, context base: ClassificationContext) -> DeviceStatus {
        var ctx = base
        ctx.target = target.osVersion
        ctx.since = target.activityFrom
        ctx.noApplicableRelease = target.noApplicableRelease
        // the target rules already chose a release this hardware can run
        ctx.supports = { _, _, _ in nil }
        var status = classify(input, context: ctx)
        status.targetVersion = target.version
        status.targetReason = target.reason
        status.targetReleased = target.released
        status.targetSource = target.source
        status.deadlineSource = target.deadlineSource?.text
        status.staleReportedDeadline = target.staleReportedDeadline
        status.staleReportedLocal = target.staleReportedLocal
        status.staleSince = target.staleSince
        status.staleReason = target.staleReason
        status.earlierStepVersion = target.earlierStepVersion
        status.earlierStepDeadline = target.earlierStepDeadline
        status.earlierStepLocal = target.earlierStepLocal
        status.earlierStepLapsed = target.earlierStepLapsed ? true : nil
        status.carriedStepVersion = target.carriedStepVersion
        status.carriedDeadline = target.carriedDeadline
        status.carriedDeadlineLocal = target.carriedDeadlineLocal
        if let step = target.earlierStepVersion, status.category == .otherUpdate,
           let range = status.diagnosis.range(of: " (intermediate version \(step))") {
            // the intermediate version is this Blueprint's own earlier step
            status.diagnosis.replaceSubrange(range, with: " \(step) first (an earlier step of this Blueprint"
                                                 + (target.earlierStepLapsed ? ", past its deadline)" : ")"))
            status.diagnosis = status.diagnosis.replacingOccurrences(of: "Installing now ", with: "Installing ")
        }
        if target.fromDevice {
            status.targetFromDevice = true
            status.ruleTarget = target.ruleVersion
            status.ruleReason = target.ruleReason
            status.targetDiffersFromRule = target.differsFromRule
        }
        if target.unknown != nil {
            // never measured against nothing: shown with its reason, left out of every count
            status.category = .targetUnknown
            status.diagnosis = "Target unknown: " + target.reason
            status.activityFrom = nil
            status.limitedByHardware = nil
            return status
        }
        status.activityFrom = target.activityFrom
        status.deadlineLocal = target.deadlineLocal
        status.deadlineDate = target.deadlineDate
        status.deadlineOffset = target.deadlineOffset
        status.pastDeadline = status.category == .onTarget ? false
            // a late earlier step: past that step's deadline, whatever the Blueprint's current one
            : target.earlierStepLapsed ? true
            : target.deadlineDate.map { $0 <= base.now }
                ?? TargetRules.isPastDeadline(target.deadlineLocal, timeZone: input.member.timeZone, now: base.now)
        // downloaded and past the deadline by more than an install takes:
        // it didn't install when it should have; just past it, it installs now
        if target.earlierStepLapsed, let step = target.earlierStepVersion, status.diagnosis.hasPrefix("Downloaded") {
            // this Blueprint's earlier step, downloaded and left past its own deadline
            status.diagnosis = "\(step) downloaded but not installed after its deadline"
        } else if let step = target.carriedStepVersion, status.pastDeadline != true, status.diagnosis.hasPrefix("Downloaded"),
                  status.diagnosis.hasSuffix("installs at the deadline") {
            // it holds the earlier step's deadline, already passed: it may install before the Blueprint's
            status.diagnosis = "Downloaded, holds the deadline of the earlier step \(step)"
        } else if status.pastDeadline == true, status.diagnosis.hasPrefix("Downloaded"), status.diagnosis.hasSuffix("installs at the deadline") {
            status.diagnosis = status.diagnosis.replacingOccurrences(
                of: "installs at the deadline",
                with: status.pastDeadlineByGrace(now: base.now) ? "not installed after the deadline" : "installs now (the deadline has just passed)")
        }
        status.limitedByHardware = target.limitedByHardware
        return status
    }

    /// The newer of two versions; the one that reads when the other doesn’t.
    static func newer(_ first: String?, _ second: String?) -> String? {
        switch (first.flatMap(OSVersion.init), second.flatMap(OSVersion.init)) {
        case let (one?, two?): return one < two ? second : first
        case (_?, nil): return first
        case (nil, _?): return second
        case (nil, nil): return first ?? second
        }
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

extension JamfPro.GroupMember {
    /// When Jamf Pro last heard from the device: its last contact or its
    /// last inventory update, whichever is newer. Jamf Pro has no last
    /// contact for some devices that do send inventory.
    nonisolated var lastSeen: Date? {
        switch (lastContact, lastInventoryUpdate) {
        case let (contact?, inventory?): max(contact, inventory)
        case let (contact, inventory): contact ?? inventory
        }
    }
}

/// CSV as spreadsheets read it: a field with a comma, quote or line break
/// is quoted, with its quotes doubled. A field that starts like a formula
/// (`=`, `+`, `-`, `@`, a tab or a carriage return), e.g. a device name
/// someone typed, gets an apostrophe first, so a spreadsheet shows it as
/// text instead of running it.
nonisolated enum CSV {
    static func line(_ fields: [String]) -> String {
        fields.map { field in
            let formula = field.unicodeScalars.first.map { "=+-@\t\r".unicodeScalars.contains($0) } ?? false
            let text = formula ? "'" + field : field
            return formula || text.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline })
                ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
        }.joined(separator: ",")
    }

    static func document(header: [String], lines: [String]) -> String {
        ([line(header)] + lines).joined(separator: "\n") + "\n"
    }
}
