import Foundation

/// One section of Help › Software Update Dashboard Help.
nonisolated struct HelpTopic: Sendable, Hashable, Identifiable {
    var id: String
    var title: String
    /// Each paragraph or list item, in plain words.
    var paragraphs: [String]
}

/// A known reason an update doesn’t install, as Apple’s own documentation
/// describes it, in the app’s own words, with a link to that page.
nonisolated struct KnownProblem: Sendable, Hashable, Identifiable {
    var id: String
    var title: String
    var text: String
    var sourceTitle: String
    var source: URL
}

/// What Help says. Only problems with a public source are listed; every
/// link was opened on 2026-11-10.
nonisolated enum HelpContent {
    static let categories = HelpTopic(id: "categories", title: "How Each Category Is Decided", paragraphs: [
        "Every device is measured against its own target, and the first rule that fits decides its category:",
        "On target: the device runs its target version or a newer one. The newer of the version the device reports and the one in Jamf Pro’s inventory counts, so a device that just installed counts as soon as either shows it.",
        "No report: Jamf Pro has no software update status for the device, and it was in contact recently.",
        "Unsupported: no release applies to the device’s hardware, or it can’t run the major release its target belongs to.",
        "Offline: the device hasn’t contacted Jamf Pro for more than 30 days.",
        "No activity: the device’s last status report is from before the update started, so it says nothing about this update.",
        "Other update: the device is downloading or installing a version below its target, for example an earlier step of this Blueprint.",
        "In progress: the device is downloading, has downloaded or is installing its target.",
        "Failed: the install failed, or the device reported update failures since the update started and isn’t downloading or installing anything now.",
        "Not started: the device reported since the update started, and nothing is pending.",
        "Target unknown: the device has no target, so it isn’t measured and isn’t in any count or the history. The reason is shown, for example Apple’s release data couldn’t be read, the Blueprint has no software update for the device’s platform, Apple has no release for it, or the device runs a beta of a newer major release.",
    ])

    static let targets = HelpTopic(id: "targets", title: "Where the Target and the Deadline Come From", paragraphs: [
        "A Blueprint that names a version: that version is the target, by the deadline the Blueprint sets, in each device’s own local time.",
        "Latest: the newest release Apple offers publicly that the device’s model can run, from the day Apple posts it. Minor updates: the newest public release of the device’s own major release. The deadline is Apple’s public posting date plus the Blueprint’s days, at the Blueprint’s time of day, in the device’s local time.",
        "What Jamf sent comes first: when a device reports a pending version from a declaration, after the update started, that version is its target, with the deadline the device reports. When it differs from the Blueprint’s rule, the device detail shows both.",
        "A deadline a device reports is a moment, shown in this Mac’s time. A deadline worked out from the rule is the device’s local time. Macs have no time zone in Jamf Pro, so their computed deadline is each Mac’s own local time.",
        "The device detail says where each target and deadline comes from.",
    ])

    static let earlierStep = HelpTopic(id: "earlier-step", title: "An Earlier Step of the Blueprint", paragraphs: [
        "When Apple posts a newer version while devices are still installing the version the Blueprint asked for before, the device first installs that earlier version: an earlier step of the Blueprint. Its target is the newer version, with the Blueprint’s current deadline. The step is shown in the device detail and isn’t counted against the device.",
        "Jamf’s status reports don’t name the declaration that sent a pending version, so the app recognizes an earlier step by its deadline: the deadline this Blueprint gives that version, or the newer version’s own deadline when Jamf already sent it.",
        "Once the step isn’t installing and its own deadline has passed by more than 4 hours, the device counts as past its deadline, also when the step failed.",
    ])

    static let readiness = HelpTopic(id: "readiness", title: "Readiness", paragraphs: [
        "Readiness counts the devices an enforced software update can’t reach as they are. Each number opens those devices in the device list.",
        "User Enrollment: iPhones and iPads enrolled this way. Apple allows the enforced update on supervised and device enrollments only.",
        "Macs not supervised: on macOS, Apple allows the enforced update on supervised Macs only.",
        "No declarative device management: the Blueprint can’t reach these devices.",
        "Never reported: Jamf Pro has no status report of the device at all.",
    ])

    static let inspect = HelpTopic(id: "inspect", title: "Inspect", paragraphs: [
        "Inspect reads a device’s status report and its declaration reports from Jamf again, and lists every reason it may not update, the likely cause first.",
        "An error from before the update started is listed but never given as the likely cause. A device on its target lists no errors from before it installed it.",
        "Where a finding is one of the known problems below, Inspect links to it.",
        "Inspect only reads: it never changes anything in Jamf.",
    ])

    static let topics = [categories, targets, earlierStep, readiness, inspect]

    private static func url(_ text: String) -> URL {
        guard let url = URL(string: text) else { preconditionFailure("Help link: \(text)") }
        return url
    }

    static let problems: [KnownProblem] = [
        KnownProblem(
            id: "bootstrap-token", title: "Bootstrap Token Not Escrowed",
            text: "On a Mac with Apple silicon, the bootstrap token lets the device management service authorize the install of a software update. Without an escrowed token, an enforced update can wait for someone to enter an administrator’s credentials on the Mac. The device detail shows the token’s status in Jamf Pro.",
            sourceTitle: "Apple: Use secure token, bootstrap token, and volume ownership in deployments",
            source: url("https://support.apple.com/guide/deployment/use-secure-and-bootstrap-tokens-dep24dbdcf9e/web")),
        KnownProblem(
            id: "network-hosts", title: "Apple’s Software Update Servers Not Reachable",
            text: "Devices download the update catalog and the updates themselves from Apple’s servers, for example gdmf.apple.com, mesu.apple.com, swscan.apple.com and updates.cdn-apple.com. A firewall, proxy or content filter that blocks them makes downloads fail or no update show up. Apple lists every host devices need.",
            sourceTitle: "Apple: Use Apple products on enterprise networks",
            source: url("https://support.apple.com/en-us/101555")),
        KnownProblem(
            id: "passcode", title: "Passcode Needed to Install",
            text: "When an enforced update isn’t installed by its deadline, iPhone and iPad ask for the device’s passcode, if one is set and wasn’t entered earlier. Until someone enters it, the downloaded update waits.",
            sourceTitle: "Apple: Install and enforce software updates for Apple devices",
            source: url("https://support.apple.com/guide/deployment/install-and-enforce-software-updates-depd30715cbb/web")),
        KnownProblem(
            id: "battery", title: "Battery Too Low",
            text: "Apple sets a minimum battery level for installing an update: for an automatic install, 30% on iPhone and iPad and 50% on a Mac. Downloading and preparing an automatic update needs the device to be connected to power.",
            sourceTitle: "Apple: About software updates for Apple devices",
            source: url("https://support.apple.com/guide/deployment/about-software-updates-depc4c80847a/web")),
        KnownProblem(
            id: "storage", title: "Not Enough Free Space",
            text: "A device needs enough free space to download, prepare and install the update. When it hasn’t, the update fails and the device’s status report gives an error.",
            sourceTitle: "Apple: About software updates for Apple devices",
            source: url("https://support.apple.com/guide/deployment/about-software-updates-depc4c80847a/web")),
        KnownProblem(
            id: "enrollment", title: "Enrollment That Doesn’t Allow an Enforced Update",
            text: "Apple’s software update enforcement declaration works on supervised and device enrollments on iPhone and iPad, and on supervised Macs only. It doesn’t apply to iPhones and iPads with User Enrollment, or to Macs that aren’t supervised.",
            sourceTitle: "Apple: software update enforcement declaration (device-management on GitHub)",
            source: url("https://github.com/apple/device-management/blob/release/declarative/declarations/configurations/softwareupdate.enforcement.specific.yaml")),
        KnownProblem(
            id: "offline", title: "Device Offline at the Deadline",
            text: "A device that misses its deadline because it was offline or didn’t meet the requirements notices that it isn’t on the required version, and goes on with the update once it’s connected again.",
            sourceTitle: "Apple: Install and enforce software updates for Apple devices",
            source: url("https://support.apple.com/guide/deployment/install-and-enforce-software-updates-depd30715cbb/web")),
    ]

    static func problem(_ id: String) -> KnownProblem? { problems.first { $0.id == id } }

    /// The known problem an Inspect finding names, if any.
    static func problem(forCause cause: String, detail: String) -> KnownProblem? {
        let id: String? = switch cause {
        case "Bootstrap token", "Bootstrap token not escrowed", "Earlier bootstrap token error": "bootstrap-token"
        case "Passcode": "passcode"
        case "Low battery": "battery"
        case "Low storage": "storage"
        case "User Enrollment", "Not supervised": "enrollment"
        case "Offline": "offline"
        case "Update error", "Earlier update error":
            if detail.range(of: "Passcode|Keybag", options: .regularExpression) != nil { "passcode" }
            else if detail.range(of: "[Bb]attery", options: .regularExpression) != nil { "battery" }
            else if detail.range(of: "[Dd]isk ?[Ss]pace|free space|[Ss]torage", options: .regularExpression) != nil { "storage" }
            else if detail.range(of: "[Nn]etwork|[Dd]ownload|[Cc]atalog|[Tt]imed ?[Oo]ut|No update found", options: .regularExpression) != nil { "network-hosts" }
            else { nil }
        default: nil
        }
        return id.flatMap(problem)
    }
}
