import Foundation
import Observation

/// Automatic refresh (Settings › Automation): every 1, 4 or 8 hours, all
/// tracked Blueprints of the connection in use, one after another, each
/// saved in the history like a manual refresh. A refresh that fails keeps
/// the previous one and is tried again at the next interval, never sooner.
/// The wait counts time asleep (the continuous clock), so after a sleep it
/// runs once to catch up, then waits a whole interval again.
@MainActor
@Observable
final class AutoRefresh {
    /// The choices in Settings; 0 is off.
    static let intervals = [0, 1, 4, 8]
    nonisolated static let hoursKey = "autoRefreshHours"
    nonisolated static let keepAwakeKey = "keepAwake"

    let model: DashboardModel
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored let keepAwake: KeepAwake

    /// Hours between refreshes; 0 is off.
    var hours: Int {
        didSet {
            defaults.set(hours, forKey: Self.hoursKey)
            schedule()
        }
    }
    /// Keep this Mac awake while automatic refresh is on (only on power).
    var keepsAwake: Bool {
        didSet {
            defaults.set(keepsAwake, forKey: Self.keepAwakeKey)
            updatePower()
        }
    }
    private(set) var lastRun: Date?
    private(set) var nextRun: Date?
    /// What went wrong in the last run, one line per Blueprint; nil when nothing did.
    private(set) var lastError: String?
    private(set) var isRunning = false

    @ObservationIgnored private var loop: Task<Void, Never>?
    /// Waits, counting time asleep; tests replace it.
    @ObservationIgnored var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0, clock: .continuous) }
    @ObservationIgnored var now: () -> Date = { Date() }

    init(model: DashboardModel, defaults: UserDefaults, keepAwake: KeepAwake? = nil) {
        self.model = model
        self.defaults = defaults
        self.keepAwake = keepAwake ?? KeepAwake()
        let saved = defaults.integer(forKey: Self.hoursKey)
        hours = Self.intervals.contains(saved) ? saved : 0
        keepsAwake = defaults.bool(forKey: Self.keepAwakeKey)
        self.keepAwake.onChange = { [weak self] in self?.updatePower() }
    }

    var isOn: Bool { hours > 0 }

    /// Starts waiting for the first refresh, one interval from now; nothing when off.
    func schedule() {
        loop?.cancel()
        loop = nil
        nextRun = nil
        updatePower()
        guard isOn else { return }
        let interval = TimeInterval(hours) * 3_600
        loop = Task { [weak self] in
            var next = (self?.now() ?? Date()).addingTimeInterval(interval)
            while !Task.isCancelled {
                guard let self else { return }
                self.nextRun = next
                let wait = max(0, next.timeIntervalSince(self.now()))
                do { try await self.sleep(.seconds(wait)) } catch { return }
                guard !Task.isCancelled else { return }
                await self.runOnce()
                // missed intervals (a sleep) don't add up: the next one counts from now
                next = Self.next(after: next, interval: interval, now: self.now())
            }
        }
    }

    /// The next refresh after one that was due at `due`: one interval after
    /// it, or after now when that has passed too (only one catch-up).
    nonisolated static func next(after due: Date, interval: TimeInterval, now: Date) -> Date {
        let following = due.addingTimeInterval(interval)
        return following > now ? following : now.addingTimeInterval(interval)
    }

    /// Refreshes every tracked Blueprint once, one after another (never in
    /// parallel). Stop ends it after the Blueprint being read.
    func runOnce() async {
        guard !isRunning else { return }
        isRunning = true
        let task = Task { [model] () -> [String] in
            var problems: [String] = []
            for tracked in model.trackedBlueprints {
                if Task.isCancelled { break }
                await model.refresh(tracked.id)
                if let error = model.errors[tracked.id] { problems.append("\(tracked.blueprintName): \(error)") }
            }
            return problems
        }
        current = task
        let problems = await task.value
        current = nil
        lastRun = now()
        lastError = problems.isEmpty ? nil : problems.joined(separator: "\n")
        isRunning = false
    }

    @ObservationIgnored private var current: Task<[String], Never>?

    /// Stops the refresh that is running; automatic refresh stays on.
    func stop() {
        current?.cancel()
    }

    /// Holds the Mac awake only while automatic refresh is on and wanted.
    private func updatePower() {
        keepAwake.update(wanted: isOn && keepsAwake)
    }
}
