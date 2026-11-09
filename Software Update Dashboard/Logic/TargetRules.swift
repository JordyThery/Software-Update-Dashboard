import Foundation
import JTKit

/// Why a device has no target. Such a device is never measured: it is
/// shown as “Target unknown” with this reason.
nonisolated enum TargetUnknown: String, Sendable, Hashable, Codable, CaseIterable {
    /// Apple’s release data couldn’t be read.
    case appleDataUnreachable
    /// The Blueprint has no software update for this device.
    case noSoftwareUpdate
    /// The Blueprint’s software update is one this app can’t read.
    case unreadableUpdate
    /// Apple’s release data has no release for the device’s platform or major.
    case noReleaseForPlatform
    /// The device runs a beta of a major newer than Apple’s newest release.
    case betaOfNewerMajor
    /// The device reports no OS version, and the rule depends on it.
    case noReportedVersion
    /// The device already runs a release Apple shipped to it that is newer
    /// than the rule’s target: the rule doesn’t fit this device.
    case runsNewerRelease
}

/// The version one device is measured against, and from when.
nonisolated struct DeviceTarget: Sendable, Hashable, Codable {
    /// Nil when there is no target (unknown, or nothing this hardware can run).
    var version: String?
    var build: String?
    /// Apple’s release date of the target, for a Blueprint that follows Apple’s releases.
    var released: Date?
    /// Status reports and errors before this don’t count: the target’s
    /// release date, the Blueprint’s last change for a specific version,
    /// or the “Update started” date set by hand.
    var activityFrom: Date?
    /// The deadline in the device’s local time, without a zone (`2026-11-23T17:00:00`).
    var deadlineLocal: String?
    /// Why this is the target, in plain language.
    var reason: String
    /// A newer major release exists that this model can’t run: measured
    /// against the newest it can, and listed among the hardware to replace.
    var limitedByHardware = false
    /// No release applies to this hardware at all: the device is unsupported.
    var noApplicableRelease = false
    /// `activityFrom` is the “Update started” date set by hand.
    var startSetByHand = false
    /// Set when there is no target; `reason` says it in plain language.
    var unknown: TargetUnknown?
    /// The target is the version the device reports pending from a
    /// declaration: what Jamf actually sent it.
    var fromDevice = false
    /// With `fromDevice`: what the Blueprint’s rule gives, and why.
    var ruleVersion: String?
    var ruleReason: String?
    /// With `fromDevice`: the rule gives another version (or none), so
    /// another declaration may be enforcing this one.
    var differsFromRule = false
    /// The Blueprint names this version itself (a specific version): what
    /// Jamf sends, not a reading of Apple’s data.
    var namedByBlueprint = false
    /// The deadline as a moment, when the device reported it with an offset.
    var deadlineDate: Date?
    /// That offset from UTC, in seconds.
    var deadlineOffset: Int?

    var osVersion: OSVersion? { version.flatMap(OSVersion.init) }
}

/// What a Blueprint’s software update means for one device. Jamf’s
/// reference (Platform API, Blueprint schema) has three settings: a specific
/// version by a deadline (`MANUAL`, no delay); the newest release, a number
/// of days (0–30) after Apple releases it, at a time of day (`AUTOMATIC`,
/// `LATEST`, across majors); and minor updates within the device’s own major,
/// days after release, at a time of day (`AUTOMATIC`, `SEMANTIC`, rule
/// `minor`). Apple’s own declaration in a custom-declarations component is
/// a specific version, optionally with a build.
nonisolated enum TargetRules {
    struct Context: Sendable {
        var block: JamfPlatform.SoftwareUpdateBlock?
        var catalog: AppleReleases.Catalog?
        var platform: AppleReleases.Platform
        /// When the Blueprint last changed: the start for a specific version.
        var blueprintChanged: Date?
        /// The “Update started” date set by hand; overrides the computed start.
        var updateStarted: Date?
        var now: Date
    }

    static func target(os: String?, model: String?, boardID: String?, osName: String, context ctx: Context) -> DeviceTarget {
        let current = os.flatMap(OSVersion.init)
        let model = model.flatMap { $0.isEmpty ? nil : $0 }
        var target: DeviceTarget
        switch ctx.block?.enforcement {
        case .specific(let text, let deadline, _)?:
            guard let version = OSVersion(text) else {
                return DeviceTarget(reason: "The Blueprint asks for a version this app can’t read (\(text))", unknown: .unreadableUpdate)
            }
            let build = ctx.block?.targetBuildVersion ?? ctx.catalog?.build(of: version, ctx.platform)
            let canRun = ctx.catalog?.supports(model: model, boardID: boardID, major: version.major, ctx.platform)
            let below = current.map { $0 < version } ?? true
            target = DeviceTarget(version: version.description, build: build, activityFrom: ctx.blueprintChanged,
                                  deadlineLocal: deadline,
                                  reason: "The Blueprint asks for \(osName) \(version)" + (deadline.map { " by \(readable($0))" } ?? ""),
                                  namedByBlueprint: true)
            if canRun == false && below {
                target.noApplicableRelease = true
                target.reason = "This model can’t run \(osName) \(version.major), which the Blueprint asks for"
            }
        case .latest(let days, let time)?:
            target = latest(current, days: days ?? 0, time: time, model: model, boardID: boardID, osName: osName, ctx)
        case .semantic(let days, let time)?:
            target = minor(current, days: days ?? 0, time: time, model: model, boardID: boardID, osName: osName, ctx)
        case .unknown?:
            return DeviceTarget(reason: "The Blueprint’s software update is a kind this app doesn’t read", unknown: .unreadableUpdate)
        case nil:
            return DeviceTarget(reason: "The Blueprint has no software update for \(osName)", unknown: .noSoftwareUpdate)
        }
        if target.unknown != nil { return target }
        if let started = ctx.updateStarted {
            target.activityFrom = started
            target.startSetByHand = true
        }
        return target
    }

    /// `LATEST`: the newest release at least `days` old, across majors, that
    /// the model can run.
    private static func latest(_ current: OSVersion?, days: Int, time: String?, model: String?, boardID: String?, osName: String,
                               _ ctx: Context) -> DeviceTarget {
        guard let catalog = ctx.catalog else {
            return DeviceTarget(reason: "Apple’s release data couldn’t be read, so the newest release isn’t known",
                                unknown: .appleDataUnreachable)
        }
        let eligible = releases(catalog, ctx.platform, days: days, now: ctx.now)
        guard let newest = eligible.first else {
            return DeviceTarget(reason: "Apple’s release data has no \(osName) release" + (days == 0 ? "" : " at least \(days) days old"),
                                unknown: .noReleaseForPlatform)
        }
        guard let pick = newestRelease(catalog, ctx.platform, model: model, boardID: boardID, days: days, now: ctx.now) else {
            return DeviceTarget(reason: "No \(osName) release runs on this model", noApplicableRelease: true)
        }
        if let unknown = runsNewer(current, than: pick, catalog, ctx.platform, days: days, now: ctx.now, osName: osName) { return unknown }
        let limited = pick.version.major < newest.version.major
        return DeviceTarget(
            version: pick.version.description, build: pick.build, released: pick.releaseDate, activityFrom: pick.releaseDate,
            deadlineLocal: pick.releaseDate.map { deadline(released: $0, days: days, time: time) },
            reason: (days == 0 ? "The newest \(osName) release: \(pick.version)" : "The newest \(osName) release at least \(days) days old: \(pick.version)")
                + (limited ? " (the newest this model can run; it can’t run \(osName) \(newest.version.major))" : ""),
            limitedByHardware: limited)
    }

    /// `SEMANTIC` minor: the newest release of the device’s own major at
    /// least `days` old.
    private static func minor(_ current: OSVersion?, days: Int, time: String?, model: String?, boardID: String?, osName: String,
                              _ ctx: Context) -> DeviceTarget {
        guard let catalog = ctx.catalog else {
            return DeviceTarget(reason: "Apple’s release data couldn’t be read, so the newest minor release isn’t known",
                                unknown: .appleDataUnreachable)
        }
        guard let current else {
            return DeviceTarget(reason: "The device reports no \(osName) version, so its minor updates aren’t known",
                                unknown: .noReportedVersion)
        }
        let inMajor = catalog.releases.filter { $0.platform == ctx.platform && $0.version.major == current.major && $0.version.extra == nil }
        let knownMajors = catalog.majors(ctx.platform)
        guard !inMajor.isEmpty else {
            if let newest = knownMajors.first, current.major > newest {
                return DeviceTarget(reason: "The device runs a beta of \(osName) \(current.major), newer than Apple’s newest release (\(osName) \(newest))",
                                    unknown: .betaOfNewerMajor)
            }
            return DeviceTarget(reason: "Apple’s release data has no \(osName) \(current.major) release", unknown: .noReleaseForPlatform)
        }
        let newestMajor = knownMajors.first ?? current.major
        let limited = newestMajor > current.major
            && catalog.supports(model: model, boardID: boardID, major: newestMajor, ctx.platform) == false
        guard let pick = newestRelease(catalog, ctx.platform, model: model, boardID: boardID, days: days, now: ctx.now,
                                       major: current.major) else {
            // nothing in this major is old enough yet: the version it runs is what it’s held to
            return DeviceTarget(version: current.description, reason: "No \(osName) \(current.major) release is \(days) days old yet",
                                limitedByHardware: limited)
        }
        if let unknown = runsNewer(current, than: pick, catalog, ctx.platform, days: days, now: ctx.now, osName: osName) { return unknown }
        return DeviceTarget(
            version: pick.version.description, build: pick.build, released: pick.releaseDate, activityFrom: pick.releaseDate,
            deadlineLocal: pick.releaseDate.map { deadline(released: $0, days: days, time: time) },
            reason: days == 0 ? "The newest \(osName) \(current.major) release: \(pick.version)"
                              : "The newest \(osName) \(current.major) release at least \(days) days old: \(pick.version)",
            limitedByHardware: limited)
    }

    /// The newest release at least `days` old that the device can run, in
    /// `major` when given: the one rule for both the target and the
    /// hardware to replace. A device Apple’s lists don’t recognize is judged
    /// by its major, so it gets that major’s newest release, never an older
    /// one only because that one has no device list. `knownOnly`: only
    /// majors Apple’s data says the model runs (for “the newest it can run”).
    static func newestRelease(_ catalog: AppleReleases.Catalog, _ platform: AppleReleases.Platform, model: String?, boardID: String?,
                              days: Int = 0, now: Date = .distantFuture, major: Int? = nil, knownOnly: Bool = false) -> AppleReleases.Release? {
        releases(catalog, platform, days: days, now: now).first { release in
            (major == nil || release.version.major == major)
                && runs(release, model: model, boardID: boardID, catalog, platform)
                && (!knownOnly || catalog.supports(model: model, boardID: boardID, major: release.version.major, platform) == true)
        }
    }

    /// A device already on a release Apple shipped to it, old enough for
    /// the rule and newer than the rule’s pick: the rule doesn’t fit it, so
    /// its target is unknown rather than lower than what it runs. A newer
    /// version that isn’t such a release (too new for the delay, a beta)
    /// is simply ahead.
    static func runsNewer(_ current: OSVersion?, than pick: AppleReleases.Release, _ catalog: AppleReleases.Catalog,
                          _ platform: AppleReleases.Platform, days: Int, now: Date, osName: String) -> DeviceTarget? {
        guard let current, current > pick.version,
              releases(catalog, platform, days: days, now: now).contains(where: { $0.version == current }) else { return nil }
        return DeviceTarget(reason: "The device runs \(osName) \(current), a release newer than the rule’s target (\(pick.version)): "
                                + "the rule doesn’t fit this device",
                            unknown: .runsNewerRelease)
    }

    /// The version the device reports pending from a declaration, as its
    /// target: what Jamf actually sent it. Used when the install reason
    /// includes `declaration`, the version is newer than what the device
    /// runs, and the report is from after the update started; otherwise
    /// the rule’s target stands. When the two differ, both are kept.
    static func fromDevice(_ rule: DeviceTarget, status: JamfPro.SoftwareUpdateStatus?, os: String?, osName: String,
                           catalog: AppleReleases.Catalog?, platform: AppleReleases.Platform, serverTimeZone: TimeZone) -> DeviceTarget {
        guard let status, let pending = status.pendingVersion, let version = pending.osVersion.flatMap(OSVersion.init),
              status.installReasons.contains(where: { $0.caseInsensitiveCompare("declaration") == .orderedSame }),
              let current = os.flatMap(OSVersion.init), version > current else { return rule }
        // a version the Blueprint names itself is what Jamf sent: a lower
        // pending version is a step on the way there (an intermediate update)
        if rule.namedByBlueprint, let named = rule.osVersion, version < named { return rule }
        if let start = rule.activityFrom {
            guard let reported = pending.updated.flatMap({ JamfPro.serverDate($0, timeZone: serverTimeZone) }), reported >= start else {
                return rule
            }
        }
        let release = catalog?.release(version, platform)
        var target = DeviceTarget(version: version.description, build: pending.buildVersion ?? release?.build,
                                  released: release?.releaseDate, activityFrom: rule.activityFrom,
                                  reason: "Jamf sent \(osName) \(version): the device reports it pending from a declaration",
                                  startSetByHand: rule.startSetByHand)
        target.fromDevice = true
        if let moment = pending.targetDate, let offset = pending.targetOffset {
            target.deadlineDate = moment
            target.deadlineOffset = offset
            target.deadlineLocal = localText(moment, offset: offset)
        } else if let local = pending.targetLocalDateTime?.replacingOccurrences(of: " ", with: "T"),
                  local.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}$", options: .regularExpression) != nil {
            target.deadlineLocal = local
        } else {
            target.deadlineLocal = rule.deadlineLocal
        }
        target.ruleVersion = rule.version
        target.ruleReason = rule.reason
        target.differsFromRule = rule.version.flatMap(OSVersion.init) != version
        return target
    }

    /// A moment as the local time at `offset`, without a zone.
    static func localText(_ date: Date, offset: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: offset)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.string(from: date)
    }

    /// Whether the model can run a release: by the release’s own device
    /// list when Apple’s data has one for this device (some releases are
    /// for some devices only), else by its major.
    static func runs(_ release: AppleReleases.Release, model: String?, boardID: String?, _ catalog: AppleReleases.Catalog,
                     _ platform: AppleReleases.Platform) -> Bool {
        catalog.supports(release: release, model: model, boardID: boardID)
            ?? (catalog.supports(model: model, boardID: boardID, major: release.version.major, platform) != false)
    }

    /// The platform’s releases at least `days` old, newest first (no Rapid
    /// Security Responses).
    static func releases(_ catalog: AppleReleases.Catalog, _ platform: AppleReleases.Platform, days: Int, now: Date) -> [AppleReleases.Release] {
        catalog.releases
            .filter { $0.platform == platform && $0.version.extra == nil }
            .filter { release in release.releaseDate.map { $0.addingTimeInterval(Double(days) * 86_400) <= now } ?? false }
            .sorted { $0.version > $1.version }
    }

    /// Apple’s release day plus `days`, at `HH:MM`, in the device’s local
    /// time (`2026-11-23T17:00:00`). Apple dates a release by its day.
    static func deadline(released: Date, days: Int, time: String?) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let day = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: released)) ?? released
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        let clock = time.flatMap { $0.range(of: "^[0-9]{2}:[0-9]{2}$", options: .regularExpression) != nil ? $0 : nil } ?? "00:00"
        return String(format: "%04d-%02d-%02dT%@:00", parts.year ?? 2000, parts.month ?? 1, parts.day ?? 1, clock)
    }

    /// The deadline as a moment in a zone; nil without one.
    static func deadlineDate(_ local: String?, timeZone: String?) -> Date? {
        guard let local, let zone = timeZone.flatMap(TimeZone.init(identifier:)) else { return nil }
        return JamfPlatform.SoftwareUpdateBlock.deadline(local, in: zone)
    }

    /// Whether the deadline has passed: in the device’s zone, or, for a
    /// device without one (Macs), in this Mac’s.
    static func isPastDeadline(_ local: String?, timeZone: String?, now: Date) -> Bool? {
        guard let local else { return nil }
        let zone = timeZone.flatMap(TimeZone.init(identifier:)) ?? .current
        return JamfPlatform.SoftwareUpdateBlock.deadline(local, in: zone).map { $0 <= now }
    }

    /// `2026-11-23T17:00:00` as people read it, without moving it to a zone.
    static func readable(_ local: String) -> String {
        guard let date = JamfPlatform.SoftwareUpdateBlock.deadline(local, in: .gmt) else { return local }
        var style = Date.FormatStyle(date: .abbreviated, time: .shortened)
        style.timeZone = .gmt
        return date.formatted(style)
    }
}
