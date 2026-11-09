import Foundation
import JTKit

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
                return DeviceTarget(reason: "The Blueprint asks for a version this app can’t read (\(text))")
            }
            let build = ctx.block?.targetBuildVersion ?? ctx.catalog?.build(of: version, ctx.platform)
            let canRun = ctx.catalog?.supports(model: model, boardID: boardID, major: version.major, ctx.platform)
            let below = current.map { $0 < version } ?? true
            target = DeviceTarget(version: version.description, build: build, activityFrom: ctx.blueprintChanged,
                                  deadlineLocal: deadline,
                                  reason: "The Blueprint asks for \(osName) \(version)" + (deadline.map { " by \(readable($0))" } ?? ""))
            if canRun == false && below {
                target.noApplicableRelease = true
                target.reason = "This model can’t run \(osName) \(version.major), which the Blueprint asks for"
            }
        case .latest(let days, let time)?:
            target = latest(days: days ?? 0, time: time, model: model, boardID: boardID, osName: osName, ctx)
        case .semantic(let days, let time)?:
            target = minor(current, days: days ?? 0, time: time, model: model, boardID: boardID, osName: osName, ctx)
        case .unknown?, nil:
            target = DeviceTarget(reason: ctx.block == nil ? "The Blueprint has no software update"
                                                           : "The Blueprint’s software update is a kind this app doesn’t read")
        }
        if let started = ctx.updateStarted {
            target.activityFrom = started
            target.startSetByHand = true
        }
        return target
    }

    /// `LATEST`: the newest release at least `days` old, across majors, that
    /// the model can run.
    private static func latest(days: Int, time: String?, model: String?, boardID: String?, osName: String, _ ctx: Context) -> DeviceTarget {
        guard let catalog = ctx.catalog else {
            return DeviceTarget(reason: "Apple’s release data couldn’t be read, so the newest release isn’t known")
        }
        let eligible = releases(catalog, ctx.platform, days: days, now: ctx.now)
        guard let newest = eligible.first else {
            return DeviceTarget(reason: "No \(osName) release is \(days) days old yet")
        }
        guard let pick = eligible.first(where: { catalog.supports(model: model, boardID: boardID, major: $0.version.major, ctx.platform) != false }) else {
            return DeviceTarget(reason: "No \(osName) release runs on this model", noApplicableRelease: true)
        }
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
            return DeviceTarget(reason: "Apple’s release data couldn’t be read, so the newest minor release isn’t known")
        }
        guard let current else { return DeviceTarget(reason: "The device reports no \(osName) version") }
        let inMajor = catalog.releases.filter { $0.platform == ctx.platform && $0.version.major == current.major && $0.version.extra == nil }
        guard !inMajor.isEmpty else {
            return DeviceTarget(reason: "Apple’s release data has no \(osName) \(current.major) releases")
        }
        let newestMajor = catalog.majors(ctx.platform).first ?? current.major
        let limited = newestMajor > current.major
            && catalog.supports(model: model, boardID: boardID, major: newestMajor, ctx.platform) == false
        guard let pick = releases(catalog, ctx.platform, days: days, now: ctx.now).first(where: { $0.version.major == current.major }) else {
            // nothing in this major is old enough yet: the version it runs is what it’s held to
            return DeviceTarget(version: current.description, reason: "No \(osName) \(current.major) release is \(days) days old yet",
                                limitedByHardware: limited)
        }
        return DeviceTarget(
            version: pick.version.description, build: pick.build, released: pick.releaseDate, activityFrom: pick.releaseDate,
            deadlineLocal: pick.releaseDate.map { deadline(released: $0, days: days, time: time) },
            reason: days == 0 ? "The newest \(osName) \(current.major) release: \(pick.version)"
                              : "The newest \(osName) \(current.major) release at least \(days) days old: \(pick.version)",
            limitedByHardware: limited)
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
