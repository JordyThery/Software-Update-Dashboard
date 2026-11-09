import Foundation
import JTKit

/// One device as Inspect gets it.
nonisolated struct InspectInput: Sendable {
    var member: JamfPro.GroupMember
    var status: JamfPro.SoftwareUpdateStatus?
    /// Its row from the latest refresh, if there is one.
    var device: DeviceStatus?
    /// The Platform API’s device ID; nil when the serial isn’t in its device list.
    var platformDeviceID: String?
    /// Its declaration reports; nil when they couldn’t be read.
    var reports: [JamfPlatform.DeclarationReport]?
    /// Why the reports couldn’t be read.
    var reportsProblem: String?
    /// Why the device couldn’t be inspected at all.
    var problem: String?

    init(member: JamfPro.GroupMember, status: JamfPro.SoftwareUpdateStatus? = nil, device: DeviceStatus? = nil,
         platformDeviceID: String? = nil, reports: [JamfPlatform.DeclarationReport]? = nil, reportsProblem: String? = nil,
         problem: String? = nil) {
        self.member = member
        self.status = status
        self.device = device
        self.platformDeviceID = platformDeviceID
        self.reports = reports
        self.reportsProblem = reportsProblem
        self.problem = problem
    }
}

/// What Inspect knows besides the device’s own data.
nonisolated struct InspectContext: Sendable {
    var blueprintID: String
    var target: OSVersion?
    /// When the update started; errors before it don’t count.
    var since: Date?
    var now: Date
    var serverTimeZone: TimeZone
    var staleDays = 30
    var minFreeSpaceMB = 6_000
    /// An update busy for longer than this without a change is stuck.
    var busyHours = 3
    /// The majors Apple’s release data knows for the platform.
    var majors: [Int] = []
    var supports: @Sendable (_ model: String?, _ boardID: String?, _ major: Int) -> Bool? = { _, _, _ in nil }
}

/// One reason a device may not update.
nonisolated struct Finding: Sendable, Hashable, Codable {
    var cause: String
    var detail: String
}

/// Every reason a device may not update, most likely first.
nonisolated struct InspectResult: Sendable, Hashable, Identifiable {
    var id: String
    var name: String
    var serial: String
    var modelIdentifier: String
    var os: String
    var diagnosis: String
    var onTarget: Bool
    var findings: [Finding]

    /// The likely cause: the first finding.
    var cause: String { onTarget ? "On target" : findings.first?.cause ?? "No cause found" }
    var detail: String {
        onTarget ? "Already on the target version"
            : findings.first?.detail ?? "Check the device in Jamf Pro (management history, declarations)"
    }

    static let csvColumns = ["serial", "device", "model", "os", "status_diagnosis", "likely_cause", "detail", "all_findings"]

    var csvLine: String {
        CSV.line([serial, name, modelIdentifier, os, diagnosis, cause, detail,
                  findings.map { "\($0.cause): \($0.detail)" }.joined(separator: " | ")])
    }
}

/// Per device, every reason it may not update, most likely first.
nonisolated enum InspectFindings {
    static func evaluate(_ input: InspectInput, context ctx: InspectContext) -> InspectResult {
        let member = input.member
        let status = input.status
        let row = input.device
        let os = row?.currentOS ?? status?.osVersion ?? member.osVersion ?? ""
        let version = OSVersion(os)
        let modelID = member.modelIdentifier ?? status?.modelIdentifier ?? ""
        let osName = Classifier.osName(isComputer: member.kind == .computer, modelIdentifier: modelID)
        let isMobile = member.kind == .mobileDevice
        let category = row?.category
        let diagnosis = row?.diagnosis ?? ""

        var findings: [Finding] = []
        func add(_ cause: String, _ detail: String) { findings.append(Finding(cause: cause, detail: detail)) }

        if let problem = input.problem { add("Could not be inspected", problem) }
        if member.managed == false { add("Not managed", "Jamf Pro lists the device as unmanaged") }
        if isMobile && member.supervised == false { add("Not supervised", "The update enforcement needs a supervised device") }
        if member.ddmEnabled == false {
            add("Declarative management off", "The device doesn’t use declarative device management, so the Blueprint can’t reach it")
        }
        if let expiry = member.mdmProfileExpiration, expiry < ctx.now {
            add("MDM profile expired", "Expired \(day(expiry))")
        }
        if let contact = member.lastContact, ctx.now.timeIntervalSince(contact) > Double(ctx.staleDays) * 86_400 {
            add("Offline", "Last contact \(day(contact))")
        }

        // The update Blueprint’s declarations on the device.
        let reports = input.reports
        let mine = (reports ?? []).filter { $0.blueprintID == ctx.blueprintID.lowercased() }
        let configurations = mine.filter { $0.type == "CONFIGURATION" }
        let activations = mine.filter { $0.type == "ACTIVATION" }
        let steps = Set(activations.compactMap(\.blueprintStepIndex)).sorted()
        let activeSteps = Set(activations.filter { $0.active == true }.compactMap(\.blueprintStepIndex)).sorted()
        let pending = mine.filter { $0.status == .pending }
        if input.platformDeviceID == nil && reports == nil {
            add("Not in the Platform device list", "Serial \(member.serialNumber ?? "?") not found, so the declaration report can’t be read")
        } else if reports == nil {
            add("Declaration report not available", "\(input.reportsProblem ?? "No answer") (the API client needs declarations:read)")
        } else if mine.isEmpty {
            add("Update Blueprint not on the device", "None of its declarations are reported (scope, or the device hasn’t synced)")
        } else if steps.isEmpty {
            // Declarations without block numbers: judge them all.
            if !pending.isEmpty { add("Update declarations not applied yet", "\(pending.count) still pending on the device") }
            for report in mine where report.validity == .invalid { add("Update declaration invalid", why(report)) }
            if !configurations.isEmpty && !configurations.contains(where: { $0.active == true }) {
                add("No update block active", "No activation condition matches \(osName) \(os)")
            }
            for report in configurations where report.active == true && !report.reasons.isEmpty {
                add("Update declaration reports a problem", why(report))
            }
        } else if activeSteps.isEmpty {
            // One activation per block; the blocks that don’t apply report
            // “predicate evaluated to false”, which is expected.
            if !pending.isEmpty { add("Update declarations not applied yet", "\(pending.count) still pending on the device") }
            let codes = Set(activations.flatMap { $0.reasons.compactMap(\.code) }).sorted().joined(separator: ", ")
            add("No update block active", "None of the \(steps.count) blocks applies to \(osName) \(os) (activation results: \(codes.isEmpty ? "none" : codes))")
        } else if activeSteps.count > 1 {
            add("Several update blocks active", "Blocks \(activeSteps.map { String($0 + 1) }.joined(separator: ", ")) all apply to \(osName) \(os)")
        } else {
            let step = activeSteps[0]
            let block = mine.filter { $0.blueprintStepIndex == step }
            let blockPending = block.filter { $0.status == .pending }
            if !blockPending.isEmpty {
                add("Update declarations not applied yet", "\(blockPending.count) of block \(step + 1) still pending on the device")
            }
            for report in block {
                if report.validity == .invalid { add("Update declaration invalid", "Block \(step + 1): \(why(report))") }
                else if report.status == .unsuccessful { add("Update declaration failed", "Block \(step + 1): \(why(report))") }
                else if report.type == "CONFIGURATION" && !report.reasons.isEmpty {
                    add("Update declaration reports a problem", "Block \(step + 1): \(why(report))")
                }
            }
        }

        if let version, let target = ctx.target, target.major > version.major,
           let next = ctx.majors.filter({ $0 > version.major }).min(),
           ctx.supports(modelID.isEmpty ? nil : modelID, status?.deviceID, next) == false {
            add("Hardware can’t run the next version", "\(modelID.isEmpty ? status?.deviceID ?? "This model" : modelID) isn’t supported by \(osName) \(next)")
        }
        let updated = status?.newestUpdate.flatMap { JamfPro.serverDate($0, timeZone: ctx.serverTimeZone) }
        if let state = status?.installState, state.isBusy, let updated {
            let pendingVersion = status?.pendingVersion?.osVersion ?? "?"
            if ctx.now.timeIntervalSince(updated) < Double(ctx.busyHours) * 3_600 {
                add("Update in progress", "\(state.rawValue) \(osName) \(pendingVersion), last change \(ago(updated, now: ctx.now))")
            } else {
                add("Update stuck", "\(state.rawValue) \(osName) \(pendingVersion) since \(ago(updated, now: ctx.now)) without any change; a restart of the device usually gets it going")
            }
        }
        if category == .notStarted, status?.installState == JamfPro.SoftwareUpdateStatus.InstallState.none,
           status?.pendingVersion == nil, status?.failure == nil {
            add("Idle: no update pending, no error", "The device reports nothing pending and no error")
        }
        if let beta = status?.betaEnrollment, beta.range(of: "^(none|null|false)$", options: [.regularExpression, .caseInsensitive]) == nil {
            add("Enrolled in a beta program", "\(beta) (build \(status?.osBuild ?? member.osBuild ?? "?")): the device follows the beta channel, so the release update may not be offered. Unenroll it (Software Update settings: beta program not allowed) and update")
        }
        if let free = member.availableSpaceMB, free < ctx.minFreeSpaceMB {
            add("Low storage", "\(gigabytes(free)) GB free of \(member.capacityMB.map(gigabytes) ?? "?") GB")
        }
        if diagnosis.localizedCaseInsensitiveContains("passcode") {
            let present = (status?.passcodePresent ?? member.passcodePresent).map { $0 ? "yes" : "no" } ?? "?"
            add("Passcode", "Passcode present: \(present); the update installs once the passcode is entered on the device, or after it’s cleared")
        }
        if member.batteryHealth == "SERVICE_RECOMMENDED" { add("Battery needs service", "Battery health: service recommended") }
        if let level = member.batteryLevel, level < 50 {
            add("Low battery", "\(level)% at the last inventory; installs need 50% or a charger")
        }
        if member.roaming == true {
            add("Roaming on mobile data", "Updates are normally downloaded over Wi-Fi: check that the device has a Wi-Fi network")
        }
        if let failTime = status?.failure?.timestamp, let failAt = JamfPro.serverDate(failTime, timeZone: ctx.serverTimeZone),
           ctx.since.map({ failAt >= $0 }) ?? true {
            let reason = Classifier.shortError(status?.failure?.reason)
            let count = status?.failure?.count.map { "\($0) \($0 == 1 ? "failure" : "failures"), " } ?? ""
            let last = String(failTime.prefix(16)).replacingOccurrences(of: "T", with: " ")
            add("Update error", "\(reason.isEmpty ? "No reason given" : reason) (\(count)last \(last))")
        }
        if let updated, let contact = member.lastContact, contact.timeIntervalSince(updated) > 2 * 86_400 {
            add("Update status not reported", "Last software update report \(day(updated)), last contact \(day(contact))")
        }
        let others = (reports ?? []).filter { $0.blueprintID != ctx.blueprintID.lowercased() }
            .filter { $0.validity == .invalid || $0.status == .unsuccessful || !$0.reasons.isEmpty }
        for other in others.prefix(3) {
            add("Other declaration with a problem", "\(other.declarationIdentifier): \(why(other))\(other.validity == .invalid ? " (invalid)" : "")")
        }

        return InspectResult(id: member.id, name: row?.name ?? member.name ?? "", serial: member.serialNumber ?? "",
                             modelIdentifier: modelID, os: os, diagnosis: diagnosis, onTarget: category == .onTarget,
                             findings: findings)
    }

    // MARK: Helpers

    /// The reasons of a declaration, as text.
    static func why(_ report: JamfPlatform.DeclarationReport) -> String {
        let parts = report.reasons.map { reason -> String in
            var text = reason.code ?? ""
            let descriptions = reason.details.compactMap(\.description).filter { !$0.isEmpty }
            if !descriptions.isEmpty { text += ": " + descriptions.joined(separator: "; ") }
            if reason.details.isEmpty, let description = reason.description, !description.isEmpty { text += " (\(description))" }
            return text
        }
        return parts.isEmpty ? "no reason given" : parts.joined(separator: "; ")
    }

    static func ago(_ date: Date, now: Date) -> String {
        let minutes = Int((now.timeIntervalSince(date) / 60).rounded(.down))
        if minutes < 0 { return "just now" }
        if minutes < 120 { return "\(minutes) min ago" }
        return "\(minutes / 60) h ago"
    }

    /// Megabytes as gigabytes with one decimal, as Jamf Pro counts them (1024).
    static func gigabytes(_ megabytes: Int) -> String {
        ((Double(megabytes) / 1024 * 10).rounded() / 10).formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier: "en_US_POSIX")))
    }

    static func day(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day())
    }
}
