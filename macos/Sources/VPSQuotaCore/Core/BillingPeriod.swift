import Foundation

/// 一个账单周期，左闭右开：`[start, end)`。
///
/// 服务商的流量额度按账单日重置，而账单日不一定是 1 号
/// （DMIT 通常是开通日，Vultr 是账号计费日），所以不能简单地按自然月统计。
public struct BillingPeriod: Hashable, Sendable {
    /// 账期起点（UTC 零点，含）
    public let start: Date
    /// 账期终点（UTC 零点，不含）
    public let end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    /// 起点的 `YYYY-MM-DD`，可直接用于 SQLite 的 `day >= ?`。
    public var startDay: String { UTCDay.string(from: start) }
    /// 终点的 `YYYY-MM-DD`（不含），可直接用于 SQLite 的 `day < ?`。
    public var endDayExclusive: String { UTCDay.string(from: end) }

    /// 账期总天数。
    public var totalDays: Int {
        UTCDay.calendar.dateComponents([.day], from: start, to: end).day ?? 30
    }

    /// 账期已过去的天数（含小数）。超出账期时钳制到 `[0, totalDays]`。
    public func elapsedDays(now: Date) -> Double {
        let seconds = now.timeIntervalSince(start)
        let days = seconds / 86_400
        return Swift.min(Swift.max(days, 0), Double(totalDays))
    }

    /// 距账期结束还剩多少个完整日历天。
    public func remainingDays(now: Date) -> Int {
        let days = UTCDay.calendar.dateComponents(
            [.day], from: UTCDay.startOfDay(now), to: end
        ).day ?? 0
        return Swift.max(0, days)
    }

    /// 判断某个 `YYYY-MM-DD` 是否落在本账期内。
    public func contains(day: String) -> Bool {
        day >= startDay && day < endDayExclusive
    }

    /// 求出包含 `now` 的账期。
    ///
    /// `resetDay` 会被钳制到 1…31；当月天数不足时（例如 31 号遇上 2 月）
    /// 取当月最后一天，这与主流服务商的做法一致。
    public static func current(
        resetDay: Int,
        now: Date = Date()
    ) -> BillingPeriod {
        let cal = UTCDay.calendar
        let clamped = Swift.min(Swift.max(resetDay, 1), 31)

        // 本月的重置时刻
        let thisMonthAnchor = anchor(inMonthOf: now, resetDay: clamped)

        if now >= thisMonthAnchor {
            // 已过本月重置日：账期是 [本月重置日, 下月重置日)
            let nextMonth = cal.date(byAdding: .month, value: 1, to: thisMonthAnchor)!
            return BillingPeriod(
                start: thisMonthAnchor,
                end: anchor(inMonthOf: nextMonth, resetDay: clamped)
            )
        } else {
            // 尚未到本月重置日：账期是 [上月重置日, 本月重置日)
            let prevMonth = cal.date(byAdding: .month, value: -1, to: thisMonthAnchor)!
            return BillingPeriod(
                start: anchor(inMonthOf: prevMonth, resetDay: clamped),
                end: thisMonthAnchor
            )
        }
    }

    /// 求 `date` 所在自然月中的重置时刻（UTC 零点）。
    ///
    /// 当月天数不足 `resetDay` 时退化为当月最后一天 —— 这是本函数存在的全部理由，
    /// 也是 `resetDay = 29/30/31` 时唯一的正确处理方式。
    private static func anchor(inMonthOf date: Date, resetDay: Int) -> Date {
        let cal = UTCDay.calendar
        let comps = cal.dateComponents([.year, .month], from: date)
        let firstOfMonth = cal.date(from: comps)!
        let daysInMonth = cal.range(of: .day, in: .month, for: firstOfMonth)!.count
        let day = Swift.min(resetDay, daysInMonth)

        var target = comps
        target.day = day
        target.hour = 0
        target.minute = 0
        target.second = 0
        return cal.date(from: target)!
    }
}
