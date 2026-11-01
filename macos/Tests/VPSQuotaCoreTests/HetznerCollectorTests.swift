import Foundation
import Testing
@testable import VPSQuotaCore

@Suite("Hetzner Cloud 采集")
struct HetznerCollectorTests {

    @Test("首次观测：没有快照，整个入出站计数器都记到当天")
    func firstObservation() {
        let (days, snapshot) = HetznerCollector.derive(
            today: "2026-11-01",
            periodStart: "2026-11-01",
            txCounter: 30_000_000,
            rxCounter: 10_000_000,
            previous: nil
        )

        #expect(days == [DailyUsage(day: "2026-11-01", rxBytes: 10_000_000, txBytes: 30_000_000)])
        #expect(snapshot == HetznerCollector.Snapshot(
            dayKey: "2026-11-01",
            dayStartTx: 0,
            dayStartRx: 0,
            txCounter: 30_000_000,
            rxCounter: 10_000_000,
            periodStart: "2026-11-01"
        ))
    }

    @Test("同一天多次观测：绝对重算出当日增量")
    func sameDayRecompute() {
        let prev = HetznerCollector.Snapshot(
            dayKey: "2026-11-01",
            dayStartTx: 10_000_000,
            dayStartRx: 5_000_000,
            txCounter: 25_000_000,
            rxCounter: 12_000_000,
            periodStart: "2026-11-01"
        )

        let (days, snapshot) = HetznerCollector.derive(
            today: "2026-11-01",
            periodStart: "2026-11-01",
            txCounter: 35_000_000,
            rxCounter: 15_000_000,
            previous: prev
        )

        #expect(days == [DailyUsage(day: "2026-11-01", rxBytes: 10_000_000, txBytes: 25_000_000)])
        #expect(snapshot.dayStartTx == 10_000_000)
        #expect(snapshot.dayStartRx == 5_000_000)
    }

    @Test("跨天：以昨日最终值作为今日基线")
    func dayRollover() {
        let prev = HetznerCollector.Snapshot(
            dayKey: "2026-11-01",
            dayStartTx: 10_000_000,
            dayStartRx: 5_000_000,
            txCounter: 25_000_000,
            rxCounter: 12_000_000,
            periodStart: "2026-11-01"
        )

        let (days, snapshot) = HetznerCollector.derive(
            today: "2026-11-02",
            periodStart: "2026-11-01",
            txCounter: 30_000_000,
            rxCounter: 14_000_000,
            previous: prev
        )

        #expect(days == [DailyUsage(day: "2026-11-02", rxBytes: 2_000_000, txBytes: 5_000_000)])
        #expect(snapshot.dayStartTx == 25_000_000)
        #expect(snapshot.dayStartRx == 12_000_000)
    }

    @Test("换账期：periodStart 变化或计数器回落时基线归零")
    func periodRollover() {
        let prev = HetznerCollector.Snapshot(
            dayKey: "2026-10-31",
            dayStartTx: 20_000_000,
            dayStartRx: 10_000_000,
            txCounter: 50_000_000,
            rxCounter: 25_000_000,
            periodStart: "2026-10-01"
        )

        let (days, snapshot) = HetznerCollector.derive(
            today: "2026-11-01",
            periodStart: "2026-11-01",
            txCounter: 2_000_000,
            rxCounter: 1_000_000,
            previous: prev
        )

        #expect(days == [DailyUsage(day: "2026-11-01", rxBytes: 1_000_000, txBytes: 2_000_000)])
        #expect(snapshot.dayStartTx == 0)
        #expect(snapshot.dayStartRx == 0)
    }

    @Test("快照落盘与加载")
    func stateStorePersistence() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = HetznerStateStore(directory: tmp)
        let s = HetznerCollector.Snapshot(
            dayKey: "2026-11-01",
            dayStartTx: 100,
            dayStartRx: 50,
            txCounter: 200,
            rxCounter: 80,
            periodStart: "2026-11-01"
        )
        try store.save(serverId: "hz-1", snapshot: s)

        let loaded = store.load(serverId: "hz-1")
        #expect(loaded == s)
        #expect(store.load(serverId: "hz-2") == nil)
    }
}
