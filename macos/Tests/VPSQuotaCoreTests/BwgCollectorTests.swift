import Foundation
import Testing
@testable import VPSQuotaCore

/// 搬瓦工采集器。KiwiVM 只给账期累计计数器，日流量靠「计数器差值」还原，
/// 这组测试把差值算法的每一种状态迁移钉死。
/// 与 Windows 端的 <c>BwgCollectorTests.cs</c> 逐条对应，期望值逐字相同。
@Suite("搬瓦工 KiwiVM 采集")
struct BwgCollectorTests {

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json"),
            "找不到 fixture：\(name).json"
        )
        return try Data(contentsOf: url)
    }

    // MARK: - 差值算法

    @Test("首次观测：没有快照，整个计数器都记到当天")
    func firstObservation() {
        let (days, snapshot) = BwgCollector.derive(
            today: "2026-10-27", counter: 5000, nextReset: 1_793_491_200, previous: nil)

        #expect(days == [DailyUsage(day: "2026-10-27", rxBytes: 0, txBytes: 5000)])
        #expect(snapshot == BwgCollector.Snapshot(
            dayKey: "2026-10-27", dayStartCounter: 0, counter: 5000, nextReset: 1_793_491_200))
    }

    @Test("同一天内多次观测是绝对重算：当天用量 = 计数器 − 当日基线，天然幂等")
    func sameDayIsAbsoluteRecompute() {
        let prev = BwgCollector.Snapshot(
            dayKey: "2026-10-27", dayStartCounter: 1000, counter: 2000, nextReset: 1_793_491_200)

        let first = BwgCollector.derive(today: "2026-10-27", counter: 3500, nextReset: 1_793_491_200, previous: prev)
        #expect(first.days == [DailyUsage(day: "2026-10-27", rxBytes: 0, txBytes: 2500)])
        #expect(first.snapshot.dayStartCounter == 1000)

        // 再来一轮：基于上一轮的快照继续增长，仍然等于「计数器 − 基线」。
        let second = BwgCollector.derive(today: "2026-10-27", counter: 4000, nextReset: 1_793_491_200, previous: first.snapshot)
        #expect(second.days == [DailyUsage(day: "2026-10-27", rxBytes: 0, txBytes: 3000)])
    }

    @Test("跨天：昨天最后一次观测值成为今天的基线，隔夜的增量记到今天")
    func dayRollover() {
        let prev = BwgCollector.Snapshot(
            dayKey: "2026-10-27", dayStartCounter: 1000, counter: 2000, nextReset: 1_793_491_200)

        let (days, snapshot) = BwgCollector.derive(
            today: "2026-10-28", counter: 2600, nextReset: 1_793_491_200, previous: prev)

        #expect(days == [DailyUsage(day: "2026-10-28", rxBytes: 0, txBytes: 600)])
        #expect(snapshot.dayStartCounter == 2000)
    }

    @Test("计数器回落 → 换账期，基线归零，新计数器整体属于新账期")
    func counterDropMeansNewCycle() {
        let prev = BwgCollector.Snapshot(
            dayKey: "2026-10-27", dayStartCounter: 1000, counter: 9000, nextReset: 1_793_491_200)

        let (days, snapshot) = BwgCollector.derive(
            today: "2026-10-27", counter: 50, nextReset: 1_803_808_800, previous: prev)

        #expect(days == [DailyUsage(day: "2026-10-27", rxBytes: 0, txBytes: 50)])
        #expect(snapshot.dayStartCounter == 0)
    }

    @Test("nextReset 变化也识别换账期 —— 防止重置后一个周期内又涨回旧值时被漏判")
    func nextResetChangeMeansNewCycle() {
        let prev = BwgCollector.Snapshot(
            dayKey: "2026-10-27", dayStartCounter: 1000, counter: 9000, nextReset: 1_793_491_200)

        // 计数器比旧账期结束时的还大（新账期跑得比旧账期整个月还多），仅靠回落检测不出来。
        let (days, _) = BwgCollector.derive(
            today: "2026-10-27", counter: 9500, nextReset: 1_803_808_800, previous: prev)

        #expect(days == [DailyUsage(day: "2026-10-27", rxBytes: 0, txBytes: 9500)])
    }

    @Test("计数器没动：当天写 0，不报错也不累加")
    func idleCounter() {
        let prev = BwgCollector.Snapshot(
            dayKey: "2026-10-27", dayStartCounter: 2000, counter: 2000, nextReset: 1_793_491_200)

        let (days, snapshot) = BwgCollector.derive(
            today: "2026-10-27", counter: 2000, nextReset: 1_793_491_200, previous: prev)

        #expect(days == [DailyUsage(day: "2026-10-27", rxBytes: 0, txBytes: 0)])
        #expect(snapshot.counter == 2000)
    }

    // MARK: - 口径折算

    @Test("官方口径：计数器与配额都要乘 monthly_data_multiplier")
    func multiplierAppliesToBothCounterAndQuota() {
        // 16 GiB × 2.5 = 40 GiB
        #expect(BwgCollector.billedBytes(17_179_869_184, multiplier: 2.5) == 42_949_672_960)
        // 缺省系数按 1 处理（老套餐/未返回该字段）
        #expect(BwgCollector.billedBytes(17_179_869_184, multiplier: 1) == 17_179_869_184)
    }

    // MARK: - 响应解析

    @Test("解析 getServiceInfo 响应：suspended 是 0/1 数字也能读")
    func parsesServiceInfo() throws {
        let parsed = try JSONDecoder().decode(
            BwgCollector.ServiceInfoResponse.self, from: fixture("kiwivm-serviceinfo"))

        #expect(parsed.error == 0)
        #expect(parsed.planMonthlyData == 42_949_672_960)
        #expect(parsed.dataCounter == 17_179_869_184)
        #expect(parsed.monthlyDataMultiplier == 2.5)
        #expect(parsed.dataNextReset == 1_794_830_400)
        #expect(parsed.suspended?.value == false)
    }

    @Test("suspended 的布尔写法（true/false）同样能读")
    func parsesBooleanSuspended() throws {
        let json = """
        { "error": 0, "data_counter": 1, "suspended": true }
        """
        let parsed = try JSONDecoder().decode(
            BwgCollector.ServiceInfoResponse.self, from: Data(json.utf8))
        #expect(parsed.suspended?.value == true)
    }

    @Test("error 非 0 时把上游 message 原样透出")
    func apiErrorMessage() {
        let message = BwgCollector.apiErrorMessage(code: 3, message: "Invalid API key")
        #expect(message.contains("error 3"))
        #expect(message.contains("Invalid API key"))
        #expect(message.contains("VEID"))
    }

    // MARK: - 重置日校验

    @Test("重置日校验：一致、不一致、月末钳制与缺时间戳")
    func resetDayValidation() {
        // 1_794_830_400 = 2026-11-16 12:00 UTC → 每月 16 号重置
        #expect(BwgCollector.resetDayMismatch(configured: 16, nextReset: 1_794_830_400) == nil)
        let november = BwgCollector.resetDayMismatch(configured: 21, nextReset: 1_794_830_400)
        #expect(november?.actual == 16 && november?.expected == 21)

        // 1_803_808_800 = 2027-02-28 10:00 UTC（平年二月末）：配置 31 号按月末钳制，视为一致
        #expect(BwgCollector.resetDayMismatch(configured: 31, nextReset: 1_803_808_800) == nil)
        // 配置 5 号则真的不一致
        let february = BwgCollector.resetDayMismatch(configured: 5, nextReset: 1_803_808_800)
        #expect(february?.actual == 28 && february?.expected == 5)

        // 上游没给时间戳就无从校验
        #expect(BwgCollector.resetDayMismatch(configured: 16, nextReset: 0) == nil)
    }

    // MARK: - 快照文件

    @Test("快照按 VEID 独立落盘，读不回来按首次观测处理")
    func stateStoreRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bwg-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = BwgStateStore(directory: dir)
        let snapshot = BwgCollector.Snapshot(
            dayKey: "2026-10-27", dayStartCounter: 100, counter: 200, nextReset: 1_793_491_200)

        try store.save(veid: "2234494", snapshot: snapshot)
        #expect(store.load(veid: "2234494") == snapshot)

        // 另一个 VEID 互不干扰
        #expect(store.load(veid: "999999") == nil)

        // 文件名里的非法字符被替换，VEID 出不了目录（"." 和 "/" 都不是字母数字）
        #expect(store.fileURL(veid: "../evil").lastPathComponent == "---evil.json")
    }
}
