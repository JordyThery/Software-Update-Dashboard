import Foundation
import Testing
import JTKit
@testable import Software_Update_Dashboard

@Suite("Classification and diagnosis")
struct ClassificationTests {
    typealias S = Sample

    @Test("CSV: a field with a comma or quote is quoted")
    func csv() {
        let device = S.classify(S.iPad(), S.status([("device.operating-system.version", "26.7.1"),
                                                    ("softwareupdate.failure-reason.reason", #"Code=1 "Bad, "quoted" thing""#),
                                                    ("softwareupdate.failure-reason.timestamp", "2026-11-05T11:00:00")]))
        let fields = device.csvLine
        #expect(fields.hasPrefix(#"1,mobile device,Test iPad 1,ZZTEST1,iPad Air,"iPad13,18",26.7.1,26.7.1,"#))
        #expect(CSV.line(["a,b", #"say "hi""#, "plain"]) == #""a,b","say ""hi""",plain"#)
        #expect(DeviceStatus.csvColumns.count == 30)
        #expect(device.id == "mobileDevice/1" && device.jamfID == "1")
    }
}
