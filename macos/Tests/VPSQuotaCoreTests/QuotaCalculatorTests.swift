import Foundation
import Testing
@testable import VPSQuotaCore

private func utc(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
    var c = DateComponents()
    c.year = y; c.month = m; c.day = d; c.hour = h
    return UTCDay.calendar.date(from: c)!
}

private let oneGiB: Int64 = 1_073_741_824

@Suite("配额折算")
struct QuotaCalculatorTests {

    /// 9 月 1–3 日：rx 合计 3 GiB，tx 合计 6 GiB。另含一条账期外的数据用于验证过滤。
    private let sample: [DailyUsage] = [
        DailyUsage(day: "2026-08-31", rxBytes: 99 * oneGiB, txBytes: 99 * oneGiB),
        DailyUsage(day: "2026-09-01", rxBytes: 1 * oneGiB, txBytes: 2 * oneGiB),
        DailyUsage(day: "2026-09-02", rxBytes: 1 * oneGiB, txBytes: 3 * oneGiB),
        DailyUsage(day: "2026-09-03", rxBytes: 1 * oneGiB, txBytes: 1 * oneGiB),
    ]

    private func server(_ mode: MeterMode, quotaGB: Double = 100) -> ServerConfig {
        ServerConfig(id: "s1", name: "测试", provider: .ssh,
                     quotaGB: quotaGB, meterMode: mode, resetDay: 1)
    }

    @Test("四种计费口径分别得到正确的用量", arguments: [
        (MeterMode.outbound, 6.0),
        (MeterMode.inbound, 3.0),
        (MeterMode.sum, 9.0),
        (MeterMode.max, 6.0),   // 逐日取大者：2 + 3 + 1
    ])
    func meterModes(mode: MeterMode, expectedGB: Double) {
        let status = QuotaCalculator.status(
            server: server(mode), days: sample, now: utc(2026, 9, 8)
        )
        #expect(abs(status.usedGB - expectedGB) < 0.001)
    }

    @Test("账期外的数据被排除")
    func excludesOutOfPeriod() {
        let status = QuotaCalculator.status(
            server: server(.sum), days: sample, now: utc(2026, 9, 8)
        )
        // 8-31 那条 198 GiB 若被计入，结果会远超 9
        #expect(status.usedGB < 10)
        #expect(status.days.count == 3)
        #expect(status.days.first?.day == "2026-09-01")
    }

    @Test("十进制 GB 进制下的用量比二进制大 7.4%")
    func decimalUnitBase() {
        var s = server(.outbound)
        s.unitBase = .decimal
        let status = QuotaCalculator.status(server: s, days: sample, now: utc(2026, 9, 8))
        // 6 GiB = 6442450944 字节 = 6.442 “十进制 GB”
        #expect(abs(status.usedGB - 6.442450944) < 0.001)
    }

    @Test("用户手填的配额优先于 API 报告的值")
    func manualQuotaWins() {
        let status = QuotaCalculator.status(
            server: server(.outbound, quotaGB: 500), days: sample,
            now: utc(2026, 9, 8), apiQuotaGB: 1000
        )
        #expect(status.quotaGB == 500)
    }

    @Test("配额填 0 时回退到 API 报告的值")
    func fallsBackToAPIQuota() {
        let status = QuotaCalculator.status(
            server: server(.outbound, quotaGB: 0), days: sample,
            now: utc(2026, 9, 8), apiQuotaGB: 1000
        )
        #expect(status.quotaGB == 1000)
    }

    @Test("配额完全未知时不计算比例，而不是当成 0")
    func unknownQuotaYieldsNil() {
        let status = QuotaCalculator.status(
            server: server(.outbound, quotaGB: 0), days: sample, now: utc(2026, 9, 8)
        )
        #expect(status.quotaGB == 0)
        #expect(status.usedFraction == nil)
        #expect(status.remainingGB == nil)
        #expect(status.severity == .unknown)
        #expect(status.willExceed == false)
    }

    @Test("严重程度阈值：70% 转黄，85% 转红")
    func severityThresholds() {
        func severity(usedGB: Double) -> ServerStatus.Severity {
            ServerStatus(
                server: server(.outbound, quotaGB: 100),
                period: BillingPeriod.current(resetDay: 1, now: utc(2026, 9, 8)),
                usedGB: usedGB, quotaGB: 100, days: []
            ).severity
        }
        #expect(severity(usedGB: 69.9) == .normal)
        #expect(severity(usedGB: 70) == .warning)
        #expect(severity(usedGB: 84.9) == .warning)
        #expect(severity(usedGB: 85) == .critical)
    }

    @Test("按当前速度外推账期总用量")
    func projection() {
        // 账期 9-01 起共 30 天；到 9-08 12:00 已过 7.5 天，用掉 6 GB
        let status = QuotaCalculator.status(
            server: server(.outbound, quotaGB: 100), days: sample, now: utc(2026, 9, 8)
        )
        let projected = try! #require(status.projectedGB)
        #expect(abs(projected - 6.0 / 7.5 * 30) < 0.01)   // = 24
        #expect(status.willExceed == false)
    }

    @Test("外推超过配额时给出超额判定")
    func projectionExceeds() {
        let status = QuotaCalculator.status(
            server: server(.outbound, quotaGB: 20), days: sample, now: utc(2026, 9, 8)
        )
        #expect(status.willExceed)   // 外推 24 GB > 配额 20 GB
    }

    @Test("账期开始不足半天时不做外推，避免被瞬时值放大")
    func noProjectionTooEarly() {
        let status = QuotaCalculator.status(
            server: server(.outbound, quotaGB: 100),
            days: [DailyUsage(day: "2026-09-01", rxBytes: 0, txBytes: oneGiB)],
            now: utc(2026, 9, 1, 2)
        )
        #expect(status.projectedGB == nil)
        #expect(status.willExceed == false)
    }

    @Test("剩余量不会出现负数")
    func remainingNeverNegative() {
        let status = ServerStatus(
            server: server(.outbound, quotaGB: 10),
            period: BillingPeriod.current(resetDay: 1, now: utc(2026, 9, 8)),
            usedGB: 25, quotaGB: 10, days: []
        )
        #expect(status.remainingGB == 0)
    }
}
