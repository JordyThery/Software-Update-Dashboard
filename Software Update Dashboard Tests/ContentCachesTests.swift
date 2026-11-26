import Foundation
import JTKit
import Testing
@testable import Software_Update_Dashboard

/// 0.4: content caches. Demo Mode and made-up files only; nothing reaches a tenant.
@Suite("0.4: content caches", .serialized)
@MainActor
struct ContentCachesTests {
    private func demoModel(_ name: String) -> DashboardModel {
        let connections = ConnectionsModel.preview(defaults: TestFiles.defaults(name))
        connections.demo.isOn = true
        return DashboardModel(connections: connections, history: StatusHistory(folder: TestFiles.folder(name)))
    }

    @Test("A sweep in Demo Mode: four caches in their cases, the caching Blueprint, ten days of trend with one reset")
    func demoSweep() async throws {
        let model = demoModel("caches-demo")
        let caches = model.caches
        #expect(caches.latest == nil && !caches.hasCaches)
        await caches.sweep()
        #expect(caches.error == nil)
        let latest = try #require(caches.latest)
        #expect(latest.caches.count == 4 && latest.problems.isEmpty)
        #expect(Set(latest.caches.map(\.name)) == ["Studio Mac 01", "Studio Mac 05", "Loaner Mac 01", "Studio Mac 07"])
        let byName = Dictionary(uniqueKeysWithValues: latest.caches.map { ($0.name, $0) })
        #expect(byName["Studio Mac 01"]?.health.level == .ok)
        #expect(byName["Studio Mac 05"]?.health.level == .warning)
        #expect(byName["Loaner Mac 01"]?.health.level == .fault)
        #expect(latest.unplanned.map(\.name) == ["Studio Mac 07"])
        let ok = try #require(byName["Studio Mac 01"])
        #expect(ok.liveFigures != nil && ok.peers?.count == 1 && ok.parents.count == 1 && ok.topCategory?.name == "Mac Software")
        #expect(ok.pressure == 8 && ok.limit == 100_000_000_000 && ok.site == "Amsterdam Studio")
        #expect(byName["Studio Mac 07"]?.liveFigures == nil, "no Blueprint asks it for live figures")
        let blueprint = try #require(latest.blueprints.first)
        #expect(blueprint.name == DemoContentCaching.blueprintName && blueprint.configured.count == 4)
        #expect(blueprint.activated == 3 && blueprint.applied == 2 && blueprint.notActivated.map(\.name) == ["Studio Mac 03"])
        #expect(blueprint.settings?.statusInterval == 900)
        // ten days of sample history, then today's sweep: one reset, Studio Mac 05's
        #expect(caches.trend.count == 4 * 11)
        #expect(caches.deltas.filter(\.isReset).map(\.cacheID) == [String(DemoContentCaching.resetCache)])
        #expect((caches.savings(of: "201", days: 7) ?? 0) > 0)
        #expect(caches.savings(of: "201", days: 90) == nil, "the trend doesn’t reach that far back")
        // a second sweep adds to the trend without seeding it again
        await caches.sweep()
        #expect(caches.trend.count == 4 * 12)
    }

    @Test("Refresh All reads the Blueprints, then the content caches")
    func refreshAll() async {
        let model = demoModel("caches-all")
        await model.refreshAll()
        #expect(model.trackedBlueprints.allSatisfy { model.results[$0.id] != nil })
        #expect(model.caches.latest?.caches.count == 4)
    }

    @Test("The automatic refresh sweeps once after the Blueprints")
    func automatic() async {
        let model = demoModel("caches-auto")
        let keepAwake = KeepAwake()
        keepAwake.hold = { 1 }
        keepAwake.release = { _ in }
        let automation = AutoRefresh(model: model, defaults: model.connections.defaults, keepAwake: keepAwake)
        await automation.runOnce()
        #expect(model.caches.latest?.caches.count == 4 && automation.lastError == nil)
    }

    @Test("By site on a Blueprint’s dashboard: the worst health of each site’s caches, or none; nothing before a cache is found")
    func bySite() async throws {
        let model = demoModel("caches-site")
        let tracked = try #require(model.trackedBlueprints.first { $0.blueprintName == "Contoso – Mac Update" })
        await model.refresh(tracked.id)
        let devices = try #require(model.results[tracked.id]).devices
        #expect(model.caches.sites(of: devices).isEmpty)
        await model.caches.sweep()
        let sites = model.caches.sites(of: devices)
        #expect(sites.map(\.name) == ["Amsterdam Studio", "Rotterdam Studio"])
        #expect(sites[0].worst == .fault && sites[0].caches == 4)
        #expect(sites[1].worst == nil && sites[1].caches == 0 && sites[1].devices > 0)
        #expect(sites.map(\.devices).reduce(0, +) == devices.count)
    }

    @Test("A connection change leaves nothing of the previous connection’s caches")
    func connectionChange() async {
        let model = demoModel("caches-switch")
        await model.caches.sweep()
        model.caches.siteFilter = SiteFilter(site: "Amsterdam Studio")
        model.connectionChanged()
        #expect(model.caches.latest == nil && model.caches.trend.isEmpty && model.caches.siteFilter == nil)
    }

    @Test("Saved per connection: the newest sweep, the trend and the known Blueprints read back")
    func archive() throws {
        let archive = CacheArchive(folder: TestFiles.folder("cache-archive"))
        #expect(archive.latest() == nil && archive.trend().isEmpty && archive.knownBlueprints().isEmpty)
        let first = Self.record(Sample.date("2026-11-20T08:00:00"), names: ["Mac A"])
        let second = Self.record(Sample.date("2026-11-21T08:00:00"), names: ["Mac A", "Mac B"])
        try archive.save(first, snapshots: Self.snapshots(first))
        try archive.save(second, snapshots: Self.snapshots(second))
        #expect(archive.latest() == second)
        #expect(archive.trend().count == 3 && archive.trend().map(\.date) == [first.date, second.date, second.date])
        try archive.saveKnownBlueprints(["b1": "2026-11-01T00:00:00Z"])
        #expect(archive.knownBlueprints() == ["b1": "2026-11-01T00:00:00Z"])
        // the same sweep saved again replaces its trend rows
        try archive.save(second, snapshots: Self.snapshots(second))
        #expect(archive.trend().count == 3)
    }

    @Test("Kept as the history: 180 days, every sweep for 7 days, then the newest of each day")
    func thinning() throws {
        let archive = CacheArchive(folder: TestFiles.folder("cache-thin"))
        let now = Sample.date("2026-11-20T12:00:00")
        // four sweeps a day for 200 days
        for day in stride(from: 199, through: 0, by: -1) {
            for hour in [1.0, 7, 13, 19] {
                let date = now.addingTimeInterval(-Double(day) * 86_400 - hour * 3_600)
                let record = Self.record(date, names: ["Mac A"])
                try archive.save(record, snapshots: Self.snapshots(record))
            }
        }
        let files = archive.files()
        #expect(files.count <= 7 * 4 + 4 + 175)
        #expect(files.count >= 7 * 4 + 170)
        let cutoff = now.addingTimeInterval(-180 * 86_400)
        #expect(archive.trend().allSatisfy { $0.date >= cutoff.addingTimeInterval(-86_400) })
        #expect(archive.latest()?.date == now.addingTimeInterval(-3_600))
    }

    @Test("A sweep with no cache: nothing by site; the texts of a Blueprint’s settings")
    func texts() {
        let empty = CacheSweepRecord(date: Sample.now, caches: [], blueprints: [], computersRead: 12, inventoryPages: 1, problems: [])
        #expect(empty.healthBySite.isEmpty && empty.unplanned.isEmpty)
        let settings = CachingBlueprintRow.Settings(cacheLimit: 100_000_000_000, parents: ["192.0.2.1"], allowPersonalCaching: false,
                                                    statusInterval: 900)
        #expect(CachingBlueprintCard.settingsLine(settings) == "Limit 100 GB · 1 parent · No personal content · Live figures every 15 min")
        #expect(CachingBlueprintCard.liveFiguresText(nil) == "No live figures")
        #expect(CachingBlueprintCard.liveFiguresText(7_200) == "Live figures every 2 hours")
        #expect(CacheSweepRecord.alertName("com.apple.AssetCache.LowSpaceAlert") == "Low Space")
    }

    // MARK: Made-up sweeps

    static func record(_ date: Date, names: [String]) -> CacheSweepRecord {
        let caches = names.enumerated().map { index, name in
            CacheRow(id: String(index + 1), name: name, health: .init(), categories: [],
                     savings: .init(served: 1_000 * Int64(index + 1), fromOrigin: 100), parents: [], alerts: [], declarations: [],
                     isUnplanned: false)
        }
        return CacheSweepRecord(date: date, caches: caches, blueprints: [], computersRead: 10, inventoryPages: 1, problems: [])
    }

    static func snapshots(_ record: CacheSweepRecord) -> [ContentCacheRules.CacheSnapshot] {
        record.caches.map { .init(date: record.date, cacheID: $0.id, served: $0.savings.served, fromOrigin: $0.savings.fromOrigin) }
    }
}
