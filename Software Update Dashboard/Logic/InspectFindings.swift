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
    /// The tracked Blueprint’s name, for readable declaration names.
    var blueprintName = "The Blueprint"
    var target: OSVersion?
    /// When the update started; errors before it don’t count.
    var since: Date?
    /// When the Blueprint last changed: a declaration report from before it
    /// says nothing about the current declarations.
    var blueprintChanged: Date?
    var now: Date
    var serverTimeZone: TimeZone
    var staleDays = 30
    var minFreeSpaceMB = 6_000
    /// The majors Apple’s release data knows for the platform.
    var majors: [Int] = []
    var supports: @Sendable (_ model: String?, _ boardID: String?, _ major: Int) -> Bool? = { _, _, _ in nil }
    /// Apple’s release data: when set, the majors and support of each
    /// device’s own platform (a Blueprint can reach iPads and Macs).
    var catalog: AppleReleases.Catalog?
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
        // the device’s own target and start, when the refresh gave it one
        let target = row?.targetVersion.flatMap(OSVersion.init) ?? ctx.target
        let since = row?.activityFrom ?? ctx.since
        let platform: AppleReleases.Platform = member.kind == .computer ? .macOS : .iOS
        let majors = ctx.catalog?.majors(platform) ?? ctx.majors
        let supports: (String?, String?, Int) -> Bool? = { model, board, major in
            if let catalog = ctx.catalog { return catalog.supports(model: model, boardID: board, major: major, platform) }
            return ctx.supports(model, board, major)
        }

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
        if let contact = member.lastSeen, ctx.now.timeIntervalSince(contact) > Double(ctx.staleDays) * 86_400 {
            add("Offline", "Last contact \(day(contact))")
        }

        // The update Blueprint’s declarations on the device, as pairs of a
        // configuration and its own activation. A minor-updates Blueprint
        // sends one pair per version range; those for other ranges report
        // Info.Predicate (and their configuration Error.ActivationFailed):
        // not for this device, so not a failure.
        let reports = input.reports
        let mine = (reports ?? []).filter { $0.blueprintID == ctx.blueprintID.lowercased() }
        let pairs = DeclarationPair.pairs(mine)
        let applicable = pairs.filter { !$0.isNotForThisDevice }
        let active = pairs.filter(\.isActive)
        func label(_ pair: DeclarationPair) -> String {
            pair.label(blueprint: ctx.blueprintName, osName: osName, deviceMajor: version?.major)
        }
        if input.platformDeviceID == nil && reports == nil {
            add("Not in the Platform device list", "Serial \(member.serialNumber ?? "?") not found, so the declaration report can’t be read")
        } else if reports == nil {
            add("Declaration report not available", "\(input.reportsProblem ?? "No answer") (the API client needs declarations:read)")
        } else if mine.isEmpty {
            add("Update Blueprint not on the device", "None of its declarations are reported (scope, or the device hasn’t synced)")
        } else if let evaluated = mine.compactMap(\.lastReportTime).max(),
                  let start = [since, ctx.blueprintChanged].compactMap({ $0 }).max(), evaluated < start {
            // the device's report is older than the current declarations: it says nothing about them
            findings.insert(Finding(cause: "Not evaluated since the update started",
                                    detail: "The device last reported its update declarations on \(day(evaluated)), before the update "
                                        + "started (\(day(start))), so its report doesn’t cover the current declarations. It reports "
                                        + "again after its next check-in"), at: 0)
        } else {
            let pending = applicable.flatMap(\.reports).filter { $0.status == .pending }
            if !pending.isEmpty { add("Update declarations not applied yet", "\(pending.count) still pending on the device") }
            if active.isEmpty {
                let others = pairs.count - applicable.count
                // the device's own ID against the predicates' lists
                let ids = [status?.deviceID ?? row?.boardID, modelID.isEmpty ? nil : modelID].compactMap { $0 }
                let listing = pairs.filter { pair in ids.contains { pair.lists($0) } }
                let idText = ids.first ?? "its model"
                let lists = listing.isEmpty
                    ? " No declaration lists \(idText), so the Blueprint doesn’t cover this hardware."
                    : " \(listing.count) list \(idText) (\(listing.map { $0.label(blueprint: ctx.blueprintName, osName: osName, deviceMajor: nil) }.joined(separator: "; "))), so their version condition excludes \(osName) \(os)."
                add("No update declaration applies",
                    "None of \(ctx.blueprintName)’s \(pairs.count) update declarations applies to \(osName) \(os)"
                        + (others > 0 ? " (\(others) \(others == 1 ? "is" : "are") for other versions or models)" : "")
                        + (pairs.contains { $0.predicate != nil } ? "." + lists : ""))
            } else if active.count > 1 {
                add("Several update declarations active", active.map(label).joined(separator: "; ") + " all apply to \(osName) \(os)")
            }
            for pair in applicable {
                for report in pair.reports {
                    if report.validity == .invalid {
                        add("Update declaration invalid", "\(label(pair)): \(why(report, names: [ctx.blueprintID.lowercased(): ctx.blueprintName]))")
                    } else if report.reasons.contains(where: { ($0.code ?? "").hasPrefix("Error.") }) {
                        add("Update declaration failed", "\(label(pair)): \(why(report, names: [ctx.blueprintID.lowercased(): ctx.blueprintName]))")
                    }
                }
            }
        }

        if let version, let target, target.major > version.major,
           let next = majors.filter({ $0 > version.major }).min(),
           supports(modelID.isEmpty ? nil : modelID, status?.deviceID, next) == false {
            add("Hardware can’t run the next version", "\(modelID.isEmpty ? status?.deviceID ?? "This model" : modelID) isn’t supported by \(osName) \(next)")
        }
        let updated = status?.newestUpdate.flatMap { JamfPro.serverDate($0, timeZone: ctx.serverTimeZone) }
        // the device still holds a deadline from before the Blueprint changed or Apple posted the version
        if let reason = row?.staleReason,
           let stale = row?.staleReportedDeadline.map(day) ?? row?.staleReportedLocal.flatMap(localDay) {
            let since = row?.staleSince.map { " (\(day($0)))" } ?? ""
            let current = DeadlineZones.text(local: row?.deadlineLocal, reported: nil).map { "; the Blueprint’s deadline is \($0)" } ?? ""
            switch reason {
            case .blueprintChanged:
                add("Declaration not refreshed since the Blueprint changed",
                    "The device still reports the deadline \(stale) from before the Blueprint’s last change\(since)\(current). "
                        + "It takes the current declaration at its next check-in")
            case .posted:
                add("Deadline reported before Apple posted this version",
                    "The device still reports the deadline \(stale) from before Apple posted this version publicly\(since)\(current). "
                        + "It takes the current deadline at its next check-in")
            }
        }
        // stuck only when a downloaded update didn't install after its
        // deadline; before it, prepared is normal; never for a device offline
        let offline = category == .offline
            || member.lastSeen.map { ctx.now.timeIntervalSince($0) > Double(ctx.staleDays) * 86_400 } ?? false
        if let state = status?.installState, state.isBusy, let updated, !offline {
            let pendingVersion = status?.pendingVersion?.osVersion ?? "?"
            // past the deadline that counts (the rule’s, for a stale report), as the row says
            if state == .prepared && row?.pastDeadline == true {
                add("Update stuck", "\(osName) \(pendingVersion) is downloaded but not installed after its deadline (last change \(ago(updated, now: ctx.now))); a restart of the device usually gets it going")
            } else if state == .prepared {
                add("Update downloaded", "\(osName) \(pendingVersion) is downloaded and installs at the deadline")
            } else {
                add("Update in progress", "\(DeviceDetailText.installState(state.rawValue)) \(osName) \(pendingVersion), last change \(ago(updated, now: ctx.now))")
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
           since.map({ failAt >= $0 }) ?? true {
            let reason = Classifier.shortError(status?.failure?.reason)
            let count = status?.failure?.count.map { "\($0) \($0 == 1 ? "failure" : "failures"), " } ?? ""
            add("Update error", "\(reason.isEmpty ? "No reason given" : reason) (\(count)last \(moment(failAt)))")
        }
        if let updated, let contact = member.lastSeen, contact.timeIntervalSince(updated) > 2 * 86_400 {
            add("Update status not reported", "Last software update report \(day(updated)), last contact \(day(contact))")
        }
        // other declarations with a problem; those not for this device aren’t
        let otherPairs = DeclarationPair.pairs((reports ?? []).filter { $0.blueprintID != ctx.blueprintID.lowercased() })
            .filter { !$0.isNotForThisDevice }
        let others = otherPairs.flatMap(\.reports)
            .filter { $0.validity == .invalid || $0.reasons.contains(where: { ($0.code ?? "").hasPrefix("Error.") }) }
        for other in others.prefix(3) {
            add("Other declaration with a problem", "\(readableName(other.declarationIdentifier, names: [:])): \(why(other, names: [:]))"
                + (other.validity == .invalid ? " (invalid)" : ""))
        }

        // a Mac’s bootstrap token: the likely cause when the last error names it
        if member.kind == .computer {
            let token = DeviceDetailText.bootstrap(member.bootstrapTokenEscrowedStatus ?? row?.bootstrapToken)
            let error = [status?.failure?.reason, row?.error].compactMap { $0 }.joined(separator: " ")
            if error.localizedCaseInsensitiveContains("bootstrap") {
                findings.insert(Finding(cause: "Bootstrap token",
                                        detail: "The last error names the bootstrap token; Jamf Pro reports it as \(token.lowercased()). "
                                            + "Without an escrowed bootstrap token the Mac can’t install an enforced update on its own"),
                                at: 0)
            } else if (member.bootstrapTokenEscrowedStatus ?? row?.bootstrapToken)?.uppercased() == "NOT_ESCROWED",
                      let why = DeviceDetailText.notEscrowedWarning(
                          appleSilicon: DeviceDetailText.isAppleSilicon(model: modelID, boardID: status?.deviceID ?? row?.boardID)) {
                // an Intel Mac updates without an escrowed token: nothing to report
                add("Bootstrap token not escrowed", "Jamf Pro reports the bootstrap token as not escrowed. " + why)
            }
        }

        return InspectResult(id: RefreshWorkflow.key(member), name: row?.name ?? member.name ?? "", serial: member.serialNumber ?? "",
                             modelIdentifier: modelID, os: os, diagnosis: diagnosis, onTarget: category == .onTarget,
                             findings: findings)
    }

    // MARK: Helpers

    /// The reasons of a declaration, as text, without IDs or hashes: a
    /// Blueprint declaration is named by its Blueprint (`names`, by
    /// lowercased Blueprint ID) and number; identifiers, server tokens and
    /// predicates in the details are left out.
    static func why(_ report: JamfPlatform.DeclarationReport, names: [String: String] = [:]) -> String {
        let skipped: Set<String> = ["identifier", "servertoken", "predicate"]
        let parts = report.reasons.map { reason -> String in
            var text = reason.code ?? ""
            let descriptions = reason.details.filter { !skipped.contains(($0.key ?? "").lowercased()) }
                .compactMap(\.description).filter { !$0.isEmpty }
            if !descriptions.isEmpty { text += ": " + descriptions.map { readableName($0, names: names) }.joined(separator: "; ") }
            if let description = reason.description, !description.isEmpty, descriptions.isEmpty {
                text += " (\(readableName(description, names: names)))"
            }
            return text
        }
        return parts.isEmpty ? "no reason given" : parts.joined(separator: "; ")
    }

    /// Text with every Blueprint declaration identifier
    /// (`Blueprint_<id>_s1_c1_sys_act12:<hash>`) replaced by “‹Blueprint›,
    /// update declaration 12” and other hashes removed.
    static func readableName(_ text: String, names: [String: String]) -> String {
        let pattern = #/Blueprint_([0-9A-Fa-f-]{36})_s([0-9]+)_c[0-9]+_[A-Za-z]+_(cfg|act)?([0-9]*)(:[0-9A-Fa-f]+)?/#
        var out = text.replacing(pattern) { match in
            let name = names[String(match.output.1).lowercased()] ?? "another Blueprint"
            let number = String(match.output.4)
            return number.isEmpty ? "\(name), step \(match.output.2)" : "\(name), update declaration \(number)"
        }
        out = out.replacing(#/:[0-9A-Fa-f]{16,}/#, with: "")
        out = out.replacing(#/[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/#, with: "‹ID›")
        return out
    }

    static func ago(_ date: Date, now: Date) -> String {
        let minutes = Int((now.timeIntervalSince(date) / 60).rounded(.down))
        if minutes < 0 { return "just now" }
        if minutes < 120 { return "\(minutes) min ago" }
        if minutes <= 48 * 60 { return "\(minutes / 60) h ago" }
        let days = minutes / (24 * 60)
        return "\(days) days ago"
    }

    /// Megabytes as gigabytes with one decimal, as Jamf Pro counts them (1024).
    static func gigabytes(_ megabytes: Int) -> String {
        ((Double(megabytes) / 1024 * 10).rounded() / 10).formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier: "en_US_POSIX")))
    }

    /// A day as the app shows it everywhere: “28 Oct 2026”.
    static func day(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    /// A local date-time without a zone (“2026-11-19T23:59:00”) as its day: “19 Nov 2026”.
    static func localDay(_ local: String) -> String? {
        guard let date = JamfPlatform.SoftwareUpdateBlock.deadline(local, in: .gmt) else { return nil }
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted)
        style.timeZone = .gmt
        return date.formatted(style)
    }

    /// A moment as the app shows it everywhere: “9 Nov 2026 at 09:11”.
    static func moment(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// A Blueprint declaration’s configuration with its own activation
/// (`…_sys_cfg12` with `…_sys_act12`), as the device reports them.
nonisolated struct DeclarationPair: Sendable, Hashable {
    var key: String
    var number: String?
    var reports: [JamfPlatform.DeclarationReport]

    var activation: JamfPlatform.DeclarationReport? { reports.first { $0.type == "ACTIVATION" } }

    /// Its activation’s predicate is false for this device (Info.Predicate):
    /// meant for other versions or models, by design.
    var isNotForThisDevice: Bool {
        activation?.reasons.contains { ($0.code ?? "").hasPrefix("Info.Predicate") } == true
    }

    var isActive: Bool { reports.contains { $0.active == true } }

    /// Whether its predicate lists this device ID or model (`IN {"J313AP", …}`).
    func lists(_ id: String) -> Bool {
        predicate?.contains("\"\(id)\"") == true
    }

    /// The predicate’s text, from the activation’s Info.Predicate reason.
    var predicate: String? {
        activation?.reasons.flatMap(\.details).first { $0.key?.lowercased() == "predicate" }?.description
            ?? activation?.reasons.compactMap(\.description).first { $0.contains("predicate") }
    }

    /// “‹Blueprint›, macOS 27.0–27.1”: the versions it is for from its
    /// predicate; for the active one the device’s own major.
    func label(blueprint: String, osName: String, deviceMajor: Int?) -> String {
        if let range = predicate.flatMap(Self.versionRange) { return "\(blueprint), \(osName) \(range)" }
        if isActive, let deviceMajor { return "\(blueprint), \(osName) \(deviceMajor) (applies to this device)" }
        return number.map { "\(blueprint), update declaration \($0)" } ?? blueprint
    }

    /// The versions in a predicate’s `MATCHES "^(27[.][0-1]([.][0-9]+)*)$"`:
    /// `27.0–27.1`; `18.0–18.7` for `18[.][0-6]…|18[.]7…`; `27` for a whole major.
    static func versionRange(_ predicate: String) -> String? {
        guard let regex = predicate.firstMatch(of: #/MATCHES\s*"([^"]+)"/#)?.output.1 else {
            // the older form: version BEGINSWITH "27." AND version < "27.0.1"
            guard let major = predicate.firstMatch(of: #/BEGINSWITH\s*"([0-9]+)\./#)?.output.1 else { return nil }
            if let below = predicate.firstMatch(of: #/version\s*<\s*"([0-9.]+)"/#)?.output.1 { return "\(major) below \(below)" }
            return String(major)
        }
        let text = String(regex)
        var major: Int?
        var minors: [Int] = []
        for match in text.matches(of: #/([0-9]+)\[\.\](?:\[([0-9])-([0-9])\]|([0-9]+))?/#) {
            guard let found = Int(match.output.1) else { continue }
            if major == nil { major = found } else if major != found { continue }
            if let low = match.output.2.flatMap({ Int($0) }), let high = match.output.3.flatMap({ Int($0) }) { minors += [low, high] }
            if let exact = match.output.4.flatMap({ Int($0) }) { minors.append(exact) }
        }
        guard let major else { return nil }
        guard let low = minors.min(), let high = minors.max() else { return "\(major)" }
        return low == high ? "\(major).\(low)" : "\(major).\(low)–\(major).\(high)"
    }

    /// The reports grouped into pairs, in number order; a declaration whose
    /// identifier has no number is a pair of its own.
    static func pairs(_ reports: [JamfPlatform.DeclarationReport]) -> [DeclarationPair] {
        var order: [String] = []
        var byKey: [String: DeclarationPair] = [:]
        for report in reports {
            let match = report.declarationIdentifier.firstMatch(of: #/^(.*_s[0-9]+_c[0-9]+_[A-Za-z]+_)(?:cfg|act)([0-9]+)$/#)
            let key = match.map { "\($0.output.1)\($0.output.2)" } ?? report.declarationIdentifier
            if byKey[key] == nil {
                order.append(key)
                byKey[key] = DeclarationPair(key: key, number: match.map { String($0.output.2) }, reports: [])
            }
            byKey[key]?.reports.append(report)
        }
        return order.compactMap { byKey[$0] }.sorted { (Int($0.number ?? "") ?? 0) < (Int($1.number ?? "") ?? 0) }
    }
}

/// Texts the device detail and Inspect share.
nonisolated enum DeviceDetailText {
    /// A Mac’s bootstrap token as Jamf Pro reports it.
    static func bootstrap(_ status: String?) -> String {
        switch status?.uppercased() {
        case "ESCROWED": "Escrowed"
        case "NOT_ESCROWED": "Not escrowed"
        case "NOT_SUPPORTED": "Not supported"
        case nil: "Not reported"
        default: status ?? "Not reported"
        }
    }

    /// An install state as a capitalized word: “Failed”, “None”; “–” when
    /// there is none.
    static func installState(_ state: String?) -> String {
        guard let state, let first = state.first else { return "–" }
        return first.uppercased() + state.dropFirst()
    }

    /// Whether a Mac has Apple silicon: by its model identifier first
    /// (“Mac14,2”, “MacBookPro18,3” yes; “MacBookPro16,1” no). The board ID
    /// from its status report only when the model says nothing, and only
    /// for what it proves: `X86LEGACYAP`, `VMM-x86_64` and “Mac-…” are Intel.
    /// A “J…AP” board alone says nothing: Intel Macs with a T2 chip report
    /// such boards too (“J152FAP”). Nil when nothing tells.
    static func isAppleSilicon(model: String?, boardID: String?) -> Bool? {
        if let model, let match = model.firstMatch(of: #/^([A-Za-z]+)(\d+),\d+$/#), let generation = Int(match.2) {
            // the first generation of each family with Apple silicon
            let first: [String: Int] = ["Mac": 13, "VirtualMac": 2, "MacBookAir": 10, "MacBookPro": 17, "Macmini": 9, "iMac": 21]
            if let from = first[String(match.1)] { return generation >= from }
            // iMacPro, MacPro (up to 7,1) and the older MacBook are Intel
            if ["iMacPro", "MacPro", "MacBook"].contains(String(match.1)) { return false }
        }
        guard let board = boardID?.trimmingCharacters(in: .whitespaces).uppercased(), !board.isEmpty else { return nil }
        if board == "X86LEGACYAP" || board == "VMM-X86_64" || board.hasPrefix("MAC-") { return false }
        return nil
    }

    /// Why a bootstrap token that isn’t escrowed matters: only on a Mac with
    /// Apple silicon, where an enforced update needs it to install on its
    /// own. Nil for an Intel Mac; said as a condition when the chip isn’t known.
    static func notEscrowedWarning(appleSilicon: Bool?) -> String? {
        switch appleSilicon {
        case true?: "Without an escrowed bootstrap token, this Mac with Apple silicon can’t install an enforced update on its own: it waits for a user to approve it."
        case false?: nil
        case nil: "On a Mac with Apple silicon, an enforced update can’t install on its own without an escrowed bootstrap token: it waits for a user to approve it."
        }
    }
}
