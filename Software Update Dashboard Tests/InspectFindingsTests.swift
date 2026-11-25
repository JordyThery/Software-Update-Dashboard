import Foundation
import Testing
import JTKit
@testable import Software_Update_Dashboard

@Suite("Inspect findings")
struct InspectFindingsTests {
    let blueprint = "6a2f0000-1111-4000-8000-00000000c0de"

    func context() -> InspectContext {
        InspectContext(blueprintID: blueprint, target: OSVersion("27.0.1"), since: Sample.updateStarted, now: Sample.now,
                       serverTimeZone: Sample.utc, majors: [27, 26, 18],
                       supports: { model, _, major in model == "iPad7,5" ? major < 27 : true })
    }

    func row(_ category: StatusCategory = .notStarted, _ diagnosis: String = "Online, update not started (no error)") -> DeviceStatus {
        Sample.classify(Sample.iPad(), Sample.status([("device.operating-system.version", "26.7.1")]))
            .with(category: category, diagnosis: diagnosis)
    }

    func report(_ step: Int, _ type: String, active: Bool, status: String = "SUCCESSFUL",
                reasons: [JamfPlatform.DeclarationReport.Reason] = []) -> JamfPlatform.DeclarationReport {
        JamfPlatform.DeclarationReport(declarationIdentifier: "Blueprint_\(blueprint)_s\(step)_c1_sys_x", type: type,
                                       status: .init(status), active: active, validity: .valid, reasons: reasons)
    }

    func evaluate(_ member: JamfPro.GroupMember = Sample.iPad(), status: JamfPro.SoftwareUpdateStatus? = nil,
                  row: DeviceStatus? = nil, reports: [JamfPlatform.DeclarationReport]? = [], platformID: String? = "P-1") -> InspectResult {
        InspectFindings.evaluate(InspectInput(member: member, status: status, device: row ?? self.row(),
                                              platformDeviceID: platformID, reports: reports), context: context())
    }

}

extension DeviceStatus {
    func with(category: StatusCategory? = nil, diagnosis: String? = nil, serial: String? = nil) -> DeviceStatus {
        var copy = self
        if let category { copy.category = category }
        if let diagnosis { copy.diagnosis = diagnosis }
        if let serial { copy.serial = serial }
        return copy
    }
}
