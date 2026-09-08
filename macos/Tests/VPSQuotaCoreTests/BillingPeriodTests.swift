import Foundation
import Testing
@testable import VPSQuotaCore

/// 构造一个 UTC 时刻，便于书写用例。
private func utc(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
    var c = DateComponents()
    c.year = y; c.month = m; c.day = d; c.hour = h
    return UTCDay.calendar.date(from: c)!
}

@Suite("账期切分")
struct BillingPeriodTests {

    @Test("重置日为 1 号时账期就是自然月")
    func resetDayOne() {
        let p = BillingPeriod.current(resetDay: 1, now: utc(2026, 9, 8))
        #expect(p.startDay == "2026-09-01")
        #expect(p.endDayExclusive == "2026-10-01")
        #expect(p.totalDays == 30)
    }

    @Test("当前时间早于本月重置日时，账期属于上一个月")
    func beforeResetDay() {
        let p = BillingPeriod.current(resetDay: 15, now: utc(2026, 9, 8))
        #expect(p.startDay == "2026-08-15")
        #expect(p.endDayExclusive == "2026-09-15")
    }

    @Test("恰好是重置日当天时，账期从当天开始")
    func onResetDay() {
        let p = BillingPeriod.current(resetDay: 15, now: utc(2026, 9, 15, 0))
        #expect(p.startDay == "2026-09-15")
        #expect(p.endDayExclusive == "2026-10-15")
    }

    @Test("重置日 31 号遇到只有 30 天的月份，退化为当月最后一天")
    func resetDay31InThirtyDayMonth() {
        // 2026-09 只有 30 天，重置点应落在 9-30；此时已过，账期为 [9-30, 10-31)
        let p = BillingPeriod.current(resetDay: 31, now: utc(2026, 9, 30, 6))
        #expect(p.startDay == "2026-09-30")
        #expect(p.endDayExclusive == "2026-10-31")
    }

    @Test("重置日 31 号遇到 2 月，退化为 2-28")
    func resetDay31InFebruary() {
        let p = BillingPeriod.current(resetDay: 31, now: utc(2026, 2, 28, 6))
        #expect(p.startDay == "2026-02-28")
        #expect(p.endDayExclusive == "2026-03-31")
    }

    @Test("闰年 2 月按 29 天处理")
    func leapYearFebruary() {
        let p = BillingPeriod.current(resetDay: 30, now: utc(2028, 2, 29, 6))
        #expect(p.startDay == "2028-02-29")
        #expect(p.endDayExclusive == "2028-03-30")
    }

    @Test("跨年时账期正确回退到上一年 12 月")
    func acrossYearBoundary() {
        let p = BillingPeriod.current(resetDay: 20, now: utc(2026, 1, 5))
        #expect(p.startDay == "2025-12-20")
        #expect(p.endDayExclusive == "2026-01-20")
    }

    @Test("非法的重置日被钳制到 1…31")
    func clampsOutOfRangeResetDay() {
        let low = BillingPeriod.current(resetDay: 0, now: utc(2026, 9, 8))
        #expect(low.startDay == "2026-09-01")

        let high = BillingPeriod.current(resetDay: 99, now: utc(2026, 9, 8))
        // 99 被钳到 31，9 月无 31 日故取 9-30；此时 9-8 尚未到达，账期为 [8-31, 9-30)
        #expect(high.startDay == "2026-08-31")
        #expect(high.endDayExclusive == "2026-09-30")
    }

    @Test("contains 按左闭右开判定")
    func containsIsHalfOpen() {
        let p = BillingPeriod.current(resetDay: 1, now: utc(2026, 9, 8))
        #expect(p.contains(day: "2026-09-01"))
        #expect(p.contains(day: "2026-09-30"))
        #expect(!p.contains(day: "2026-08-31"))
        #expect(!p.contains(day: "2026-10-01"))
    }

    @Test("已过天数与剩余天数")
    func elapsedAndRemaining() {
        let p = BillingPeriod.current(resetDay: 1, now: utc(2026, 9, 8))
        // 9-01 00:00 到 9-08 12:00 是 7.5 天
        #expect(abs(p.elapsedDays(now: utc(2026, 9, 8)) - 7.5) < 0.01)
        // 9-08 当天零点到 10-01 零点还有 23 天
        #expect(p.remainingDays(now: utc(2026, 9, 8)) == 23)
    }

    @Test("已过天数被钳制在账期范围内")
    func elapsedIsClamped() {
        let p = BillingPeriod.current(resetDay: 1, now: utc(2026, 9, 8))
        #expect(p.elapsedDays(now: utc(2026, 8, 20)) == 0)
        #expect(p.elapsedDays(now: utc(2026, 11, 1)) == Double(p.totalDays))
    }
}
