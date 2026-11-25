import Foundation
import JTKit
import Testing
@testable import Software_Update_Dashboard

/// 0.3.2 review fixes: a refresh that measured nothing keeps the remembered
/// deadlines (M1), and a Mac’s rescheduled time is never taken for Jamf’s
/// deadline once the Blueprint’s devices have reported it (L1). Made-up
/// devices, shaped like the 24 and 25 Nov snapshots.
@Suite("0.3.2 fixes: remembered deadlines kept, a Mac’s rescheduled time")
struct PointThreeTwoFixTests {
    typealias Memory = DeadlineMemoryTests
    static let jamfMinute = PostingBasis.minute(Sample.date("2026-11-23T22:59:00"))
    static let memory = ReportedDeadlines(
        postings: [Memory.key: .init(posted: Memory.firstPosting, seen: Sample.date("2026-11-20T08:00:00"))],
        moments: [Memory.key: [.init(minute: jamfMinute, seen: Sample.date("2026-11-20T08:00:00"))]])

    static func mac(_ id: String, os: String = "26.7.2") -> JamfPro.GroupMember {
        Sample.mac(id, os: os, model: "MacBookPro18,3")
    }

    static func classify(_ input: DeviceInput, _ workflow: RefreshWorkflow, known: PostingBasis, now: Date) -> DeviceStatus {
        workflow.classify(input, blocks: [Memory.block], blueprint: Memory.blueprint, tracked: Memory.tracked, now: now, known: known)
    }

    // MARK: M1

    @Test("A refresh with no devices keeps the remembered deadline; the next one, where nobody reports it, still uses it")
    func emptyRefreshKeepsMemory() throws {
        // a refresh that read no devices at all (a scope group answering empty for a moment)
        let empty = try Memory.workflow(remembered: Self.memory)
            .deadlineBasis([], blocks: [Memory.block], blueprint: Memory.blueprint, tracked: Memory.tracked, now: Sample.date("2026-11-24T06:00:00"))
        // what it found would forget everything: it isn't kept, as the history isn't
        #expect(empty.remember.postings.isEmpty)
        let kept = DashboardModel.reportedDeadlinesToKeep(updated: empty.remember, previous: Self.memory, counts: CategoryCounts([]))
        #expect(kept == Self.memory)
        // the next refresh: one Mac has installed, the other never reported
        let waiting = DeviceInput(member: Self.mac("2"), status: nil)
        let inputs = [DeviceInput(member: Self.mac("1", os: "26.7.3"),
                                  status: Memory.status(pending: nil, deadline: nil, state: "none", os: "26.7.3")), waiting]
        let now = Sample.date("2026-11-25T05:04:00")
        let workflow = try Memory.workflow(remembered: kept)
        let basis = workflow.deadlineBasis(inputs, blocks: [Memory.block], blueprint: Memory.blueprint, tracked: Memory.tracked, now: now)
        let device = Self.classify(waiting, workflow, known: basis.known, now: now)
        #expect(device.deadlineLocal == "2026-11-23T23:59:00" && device.deadlineSource == "As the Blueprint’s devices reported it earlier")
        #expect(device.pastDeadline == true)
        // a refresh worth saving keeps what it found
        let worth = CategoryCounts([device])
        #expect(DashboardModel.reportedDeadlinesToKeep(updated: basis.remember, previous: kept, counts: worth) == basis.remember)
    }

    // MARK: L1

    @Test("Others reported 23 Nov 22:59 UTC; a Mac reports 24 Nov 05:29 at 04:29: not remembered, a next install attempt, past the deadline")
    func rescheduledMinuteNotJamfs() throws {
        let jamf = DeviceInput(member: Self.mac("1"), status: Memory.status(updated: "2026-11-10T08:00:00"))
        let rescheduled = DeviceInput(member: Self.mac("2"),
                                      status: Memory.status(deadline: "2026-11-24 05:29:00 +0000", updated: "2026-11-24T04:29:00"))
        let now = Sample.date("2026-11-24T06:33:00")
        let workflow = try Memory.workflow()
        let basis = workflow.deadlineBasis([jamf, rescheduled], blocks: [Memory.block], blueprint: Memory.blueprint,
                                           tracked: Memory.tracked, now: now)
        #expect(basis.known.reportedMinutes[Memory.key] == [Self.jamfMinute])
        #expect(basis.remember.moments[Memory.key]?.map(\.minute) == [Self.jamfMinute])
        let device = Self.classify(rescheduled, workflow, known: basis.known, now: now)
        #expect(device.nextInstallAttempt == Sample.date("2026-11-24T05:29:00"))
        #expect(device.deadlineLocal == "2026-11-23T23:59:00" && device.deadlineDate == nil)
        #expect(device.pastDeadline == true)
        // the same from memory alone, a later refresh without the other Mac's report
        let later = try Memory.workflow(remembered: Self.memory)
        let alone = later.deadlineBasis([rescheduled], blocks: [Memory.block], blueprint: Memory.blueprint, tracked: Memory.tracked, now: now)
        #expect(alone.known.reportedMinutes[Memory.key] == [Self.jamfMinute])
        #expect(Self.classify(rescheduled, later, known: alone.known, now: now).nextInstallAttempt == Sample.date("2026-11-24T05:29:00"))
        // with nothing reported or remembered, a Mac's minutes are checked as before 0.3.2
        let unknown = Self.classify(rescheduled, workflow, known: PostingBasis(reported: [Memory.key: Memory.firstPosting]), now: now)
        #expect(unknown.nextInstallAttempt == nil && unknown.deadlineSource == "Reported by the device")
    }

    @Test("A Mac in another time zone reporting 23 Nov 21:59 UTC on 20 Nov: remembered as Jamf’s deadline too")
    func otherZoneRemembered() throws {
        let otherZone = DeviceInput(member: Self.mac("3"),
                                    status: Memory.status(deadline: "2026-11-23 21:59:00 +0000", updated: "2026-11-20T08:00:00"))
        let workflow = try Memory.workflow(remembered: Self.memory)
        let basis = workflow.deadlineBasis([otherZone], blocks: [Memory.block], blueprint: Memory.blueprint, tracked: Memory.tracked,
                                           now: Sample.date("2026-11-20T09:00:00"))
        let other = PostingBasis.minute(Sample.date("2026-11-23T21:59:00"))
        #expect(basis.known.reportedMinutes[Memory.key] == [Self.jamfMinute, other])
        #expect(Set(basis.remember.moments[Memory.key]?.map(\.minute) ?? []) == [Self.jamfMinute, other])
        #expect(Self.classify(otherZone, workflow, known: basis.known, now: Sample.date("2026-11-20T09:00:00")).deadlineSource
                == "Reported by the device")
    }

    @Test("A Mac re-reporting 22:59 at 22:59:20 when the install starts adds nothing and changes nothing")
    func reReportAtDeadline() throws {
        let starting = DeviceInput(member: Self.mac("4"),
                                   status: Memory.status(deadline: "2026-11-23 22:59:11 +0000", state: "installing",
                                                         updated: "2026-11-23T22:59:20"))
        let now = Sample.date("2026-11-23T23:10:00")
        let workflow = try Memory.workflow(remembered: Self.memory)
        let basis = workflow.deadlineBasis([starting], blocks: [Memory.block], blueprint: Memory.blueprint, tracked: Memory.tracked, now: now)
        #expect(basis.remember.moments == Self.memory.moments)
        #expect(basis.known.reportedMinutes[Memory.key] == [Self.jamfMinute])
        let device = Self.classify(starting, workflow, known: basis.known, now: now)
        #expect(device.nextInstallAttempt == nil && device.deadlineSource == "Reported by the device")
        #expect(device.deadlineDate == Sample.date("2026-11-23T22:59:11"))
        // and the rule itself: reported after the earliest known deadline, or before it
        let added = RefreshWorkflow.newDeadlineMinutes(
            [Memory.key: [(Self.jamfMinute, Sample.date("2026-11-23T22:59:20")),
                          (PostingBasis.minute(Sample.date("2026-11-24T05:29:00")), Sample.date("2026-11-24T04:29:00"))]],
            known: [Memory.key: [Self.jamfMinute]])
        #expect(added.isEmpty)
        #expect(RefreshWorkflow.newDeadlineMinutes([Memory.key: [(Self.jamfMinute, Sample.date("2026-11-10T08:00:00"))]], known: [:])
                == [Memory.key: [Self.jamfMinute]])
    }
}
