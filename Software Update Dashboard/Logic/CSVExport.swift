import Foundation
import JTKit

// The app’s own exports of the shared rows (`SoftwareUpdateRules`), as before 1.9.0.

extension DeviceStatus {
    /// The CSV’s columns, in order.
    nonisolated static let csvColumns = ["jamf_pro_id", "kind", "name", "serial", "model", "model_id", "inventory_os", "reported_os",
                                         "target", "deadline", "deadline_source", "past_deadline", "install_state", "pending_version", "category",
                                         "diagnosis", "error", "error_time", "error_since_update", "passcode_present", "last_contact",
                                         "status_updated", "time_zone", "rapid_security_response", "beta_enrollment", "install_reason",
                                         "failure_count", "filevault", "battery_health", "next_install_attempt"]

    nonisolated var csvLine: String {
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
                         failureCount.map(String.init) ?? "", fileVault ?? "", batteryHealth ?? "",
                         nextInstallAttempt.map(date) ?? nextInstallAttemptLocal ?? ""])
    }
}

extension InspectResult {
    nonisolated static let csvColumns = ["serial", "device", "model", "os", "status_diagnosis", "likely_cause", "detail", "all_findings"]

    nonisolated var csvLine: String {
        CSV.line([serial, name, modelIdentifier, os, diagnosis, cause, detail,
                  findings.map { "\($0.cause): \($0.detail)" }.joined(separator: " | ")])
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

extension String {
    nonisolated var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
