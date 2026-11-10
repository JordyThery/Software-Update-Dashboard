import Foundation
import JTKit
import ServiceManagement
import SwiftUI
import Testing
@testable import Software_Update_Dashboard

/// 0.3, round 2: automatic refresh (B), keeping the Mac awake (C), open at
/// login (M), the menu bar item (L) and notifications (D). Demo Mode and
/// made-up devices only; nothing reaches a tenant, the login items or the
/// notification center.
@MainActor
private func demoModel(_ name: String) -> (DashboardModel, AutoRefresh) {
    let connections = ConnectionsModel.preview(defaults: TestFiles.defaults(name))
    connections.demo.isOn = true
    let model = DashboardModel(connections: connections, history: StatusHistory(folder: TestFiles.folder(name)))
    let keepAwake = KeepAwake()
    keepAwake.hold = { 1 }
    keepAwake.release = { _ in }
    return (model, AutoRefresh(model: model, defaults: connections.defaults, keepAwake: keepAwake))
}

/// A clock the fake sleep moves forward, and what it was asked to wait.
private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = Sample.date("2026-11-10T10:00:00")
    private var waits: [TimeInterval] = []
    var now: Date { lock.withLock { time } }
    var waited: [TimeInterval] { lock.withLock { waits } }
    func sleep(_ duration: Duration, stopAfter: Int) throws {
        try lock.withLock {
            guard waits.count < stopAfter else { throw CancellationError() }
            let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
            waits.append(seconds)
            time = time.addingTimeInterval(seconds)
        }
    }
}

@Suite("0.3: automatic refresh", .serialized)
@MainActor
struct AutoRefreshTests {
    @Test("After a sleep it catches up once: the next refresh counts from now, missed ones don’t add up")
    func catchUpOnce() {
        let due = Sample.date("2026-11-10T10:00:00")
        #expect(AutoRefresh.next(after: due, interval: 4 * 3_600, now: Sample.date("2026-11-10T10:01:00"))
                == Sample.date("2026-11-10T14:00:00"))
        // asleep for 13 hours: three refreshes missed, one runs, the next is 4 hours later
        #expect(AutoRefresh.next(after: due, interval: 4 * 3_600, now: Sample.date("2026-11-10T23:00:00"))
                == Sample.date("2026-11-11T03:00:00"))
    }

    @Test("One run refreshes every tracked Blueprint one after another, each saved in the history")
    func runOnceSerially() async throws {
        let (model, automation) = demoModel("auto-serial")
        var most = 0
        let watcher = Task { @MainActor in
            while !Task.isCancelled {
                most = max(most, model.refreshing.count)
                await Task.yield()
            }
        }
        await automation.runOnce()
        watcher.cancel()
        #expect(most <= 1)
        for tracked in model.trackedBlueprints {
            #expect(model.results[tracked.id] != nil)
            #expect(!model.snapshots(tracked.id).isEmpty)
        }
        #expect(automation.lastRun != nil && automation.lastError == nil && !automation.isRunning)
        // a second run adds one refresh to each history
        let before = model.trackedBlueprints.map { model.snapshots($0.id).count }
        await automation.runOnce()
        #expect(model.trackedBlueprints.map { model.snapshots($0.id).count } == before.map { $0 + 1 })
    }

    @Test("A failed refresh keeps the previous one and says so; the next try waits a whole interval")
    func failureWaitsForNextInterval() async throws {
        let (model, automation) = demoModel("auto-fail")
        await automation.runOnce()
        let shown = model.trackedBlueprints.compactMap { model.results[$0.id]?.date }
        await model.setDemoSituation(.appleDataUnreachable)
        await automation.runOnce()
        #expect(automation.lastError?.contains("Apple’s release data") == true)
        // the previous refresh stays on screen
        #expect(model.trackedBlueprints.compactMap { model.results[$0.id]?.date } == shown)

        let clock = FakeClock()
        automation.now = { clock.now }
        automation.sleep = { try clock.sleep($0, stopAfter: 3) }
        automation.hours = 4
        for _ in 0..<400 where clock.waited.count < 3 { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(100))
        // every wait is a whole interval, also after the failing runs
        #expect(clock.waited.count == 3 && clock.waited.allSatisfy { abs($0 - 4 * 3_600) < 1 })
        automation.hours = 0
        #expect(automation.nextRun == nil)
    }

    @Test("Stop ends the run that is going on; automatic refresh stays on")
    func stop() async throws {
        let (model, automation) = demoModel("auto-stop")
        let run = Task { await automation.runOnce() }
        await Task.yield()
        automation.stop()
        await run.value
        #expect(!automation.isRunning)
        #expect(model.trackedBlueprints.contains { model.errors[$0.id] == "Stopped." } || model.refreshing.isEmpty)
    }

    @Test("The interval and the keep-awake choice are saved; anything else reads as off")
    func saved() {
        let defaults = TestFiles.defaults("auto-saved")
        let connections = ConnectionsModel.preview(defaults: defaults)
        let model = DashboardModel(connections: connections, history: StatusHistory(folder: TestFiles.folder("auto-saved")))
        let automation = AutoRefresh(model: model, defaults: defaults)
        automation.sleep = { _ in throw CancellationError() }
        automation.hours = 8
        automation.keepsAwake = true
        let again = AutoRefresh(model: model, defaults: defaults)
        #expect(again.hours == 8 && again.keepsAwake)
        defaults.set(3, forKey: AutoRefresh.hoursKey)
        #expect(AutoRefresh(model: model, defaults: defaults).hours == 0)
        automation.hours = 0
    }
}

@Suite("0.3: keep this Mac awake")
@MainActor
struct KeepAwakeTests {
    @Test("Held only while wanted and on power; released on battery and when automatic refresh is off")
    func onPowerOnly() {
        let keepAwake = KeepAwake()
        var onPower = true
        var held: Set<IOPMAssertionID> = []
        var next: IOPMAssertionID = 1
        keepAwake.isOnPower = { onPower }
        keepAwake.hold = { defer { next += 1 }; held.insert(next); return next }
        keepAwake.release = { held.remove($0) }
        keepAwake.update(wanted: true)
        #expect(keepAwake.isHolding && held.count == 1)
        // unplugged: released at once; plugged in again: held again
        onPower = false
        keepAwake.powerChanged()
        #expect(!keepAwake.isHolding && held.isEmpty)
        onPower = true
        keepAwake.powerChanged()
        #expect(keepAwake.isHolding && held.count == 1)
        keepAwake.update(wanted: false)
        #expect(!keepAwake.isHolding && held.isEmpty)
    }

    @Test("Automatic refresh wants it only when it is on and the option is chosen (off by default)")
    func followsAutomation() {
        let (_, automation) = demoModel("awake-auto")
        automation.sleep = { _ in throw CancellationError() }
        automation.keepAwake.isOnPower = { true }
        #expect(!automation.keepsAwake)
        automation.hours = 4
        #expect(!automation.keepAwake.isHolding)
        automation.keepsAwake = true
        #expect(automation.keepAwake.isHolding)
        automation.hours = 0
        #expect(!automation.keepAwake.isHolding)
    }
}

@Suite("0.3: open at login and the menu bar item")
@MainActor
struct LoginAndMenuBarTests {
    @Test("Open at Login shows what the system says, also after a change in System Settings")
    func loginItem() {
        var status = SMAppService.Status.notRegistered
        var changes: [Bool] = []
        let item = LoginItem(canChange: true)
        item.status = { status }
        item.change = { on in
            changes.append(on)
            status = on ? .enabled : .notRegistered
        }
        item.refresh()
        #expect(item.state == .off)
        item.set(true)
        #expect(item.state == .on && changes == [true])
        // turned off in System Settings meanwhile
        status = .notRegistered
        item.refresh()
        #expect(item.state == .off)
        status = .requiresApproval
        item.refresh()
        #expect(item.state == .needsApproval)
    }

    @Test("A test or sandbox run never changes the login items")
    func loginItemUnavailable() {
        let item = LoginItem(canChange: false)
        var changed = false
        item.change = { _ in changed = true }
        item.set(true)
        #expect(item.state == .unavailable && !changed)
        #expect(LoginItem().state == .unavailable)
    }

    @Test("The menu bar item shows by default and can be hidden; its dots follow the share, with the number beside them")
    func menuBar() {
        let defaults = TestFiles.defaults("menubar")
        let setting = MenuBarSetting(defaults: defaults)
        #expect(setting.isShown)
        setting.isShown = false
        #expect(!MenuBarSetting(defaults: defaults).isShown)
        #expect(ShareLevel.color(95) == .green && ShareLevel.color(75) == .orange && ShareLevel.color(10) == .red)
        #expect(ShareLevel.color(nil) == .gray)
    }
}

@Suite("0.3: notifications")
@MainActor
struct NotificationTests {
    private func devices(onTarget: Int, failed: [String] = [], stuck: [String] = [], total: Int = 10) -> [DeviceStatus] {
        (1...total).map { number in
            var device = Sample.classify(Sample.iPad("\(number)"), nil)
            device.category = number <= onTarget ? .onTarget : .notStarted
            device.diagnosis = "Online, update not started (no error)"
            if failed.contains("\(number)") { device.category = .failed }
            if stuck.contains("\(number)") {
                device.category = .inProgress
                device.diagnosis = "Downloaded, not installed after the deadline"
            }
            return device
        }
    }

    @Test("The share reaching or dropping below the level notifies; the first refresh and no change don’t")
    func share() {
        let rule = NotificationRule(shareLevel: 80)
        #expect(RefreshNotices.between(previous: nil, current: devices(onTarget: 9), rule: rule, name: "B").isEmpty)
        let up = RefreshNotices.between(previous: devices(onTarget: 7), current: devices(onTarget: 8), rule: rule, name: "B")
        #expect(up.map(\.body) == ["80% of the devices are on target: the share reached 80%."])
        let down = RefreshNotices.between(previous: devices(onTarget: 9), current: devices(onTarget: 5), rule: rule, name: "B")
        #expect(down.first?.body.contains("dropped below 80%") == true)
        #expect(RefreshNotices.between(previous: devices(onTarget: 9), current: devices(onTarget: 8), rule: rule, name: "B").isEmpty)
        // off: nothing
        #expect(RefreshNotices.between(previous: devices(onTarget: 7), current: devices(onTarget: 8), rule: NotificationRule(), name: "B").isEmpty)
    }

    @Test("Devices newly failed or stuck notify; those already so don’t")
    func failedOrStuck() {
        let rule = NotificationRule(failedOrStuck: true)
        let notices = RefreshNotices.between(previous: devices(onTarget: 2, failed: ["5"]),
                                             current: devices(onTarget: 2, failed: ["5", "6"], stuck: ["7"]), rule: rule, name: "B")
        #expect(notices.map(\.body) == ["1 device newly failed, 1 device newly stuck after the deadline: Test iPad 6, Test iPad 7."])
        #expect(RefreshNotices.between(previous: devices(onTarget: 2, failed: ["5"]), current: devices(onTarget: 2, failed: ["5"]),
                                       rule: rule, name: "B").isEmpty)
    }

    @Test("Permission is asked when a notification is turned on, once; Demo Mode asks nothing, saves nothing and sends nothing")
    func permissionAndDemo() async {
        let defaults = TestFiles.defaults("notify")
        let log = ActivityLog()
        let notifier = Notifier(defaults: defaults, activityLog: log)
        var asked = 0
        var sent: [RefreshNotice] = []
        notifier.authorize = { asked += 1; return true }
        notifier.deliver = { sent.append($0) }
        let id = UUID()
        await notifier.setRule(NotificationRule(shareLevel: 90), for: id, demo: true)
        #expect(asked == 0 && defaults.data(forKey: Notifier.rulesKey) == nil)
        #expect(notifier.rule(for: id, demo: true).shareLevel == 90 && notifier.rule(for: id, demo: false).shareLevel == nil)
        notifier.post([RefreshNotice(title: "B", body: "Changed")], demo: true)
        #expect(sent.isEmpty && log.entries.contains { "\($0.operation) \($0.detail)".contains("Demo Mode, notification not sent") })

        await notifier.setRule(NotificationRule(shareLevel: 90), for: id, demo: false)
        await notifier.setRule(NotificationRule(shareLevel: 90, failedOrStuck: true), for: id, demo: false)
        #expect(asked == 1)
        #expect(Notifier(defaults: defaults, activityLog: log).rule(for: id, demo: false).failedOrStuck)
        notifier.post([RefreshNotice(title: "B", body: "Changed")], demo: false)
        #expect(sent.count == 1)
        // refused: said so, and asked again on the next change
        notifier.authorize = { asked += 1; return false }
        await notifier.setRule(NotificationRule(), for: id, demo: false)
        await notifier.setRule(NotificationRule(failedOrStuck: true), for: id, demo: false)
        #expect(notifier.permissionProblem != nil && asked == 2)
    }

    @Test("In Demo Mode the first refresh never notifies; a second without changes doesn’t either")
    func demoRefreshes() async throws {
        let (model, _) = demoModel("notify-demo")
        let tracked = try #require(model.trackedBlueprints.first)
        await model.notifier.setRule(NotificationRule(shareLevel: 50, failedOrStuck: true), for: tracked.id, demo: true)
        await model.refresh(tracked.id)
        await model.refresh(tracked.id)
        #expect(model.notifier.posted.isEmpty)
    }
}
