import Foundation

/// 一台服务器在当前账期内的用量结论，供 UI 直接渲染。
public struct ServerStatus: Identifiable, Hashable, Sendable {
    public var id: String { server.id }
    public var server: ServerConfig

    /// 当前账期区间
    public var period: BillingPeriod
    /// 本次状态的求值时刻。外推与"剩余天数"都以它为准，
    /// 而不是各自去读墙上时钟 —— 否则同一个状态对象里的几个数字会互相对不上，也无法测试。
    public var evaluatedAt: Date
    /// 按 meterMode 折算后的已用量（GB）
    public var usedGB: Double
    /// 实际生效的配额（GB）。Vultr 且 quotaGB == 0 时来自 API 的 allowed_bandwidth。
    public var quotaGB: Double
    /// 账期内的每日明细，用于画趋势图（已按日期升序）
    public var days: [DailyUsage]

    /// 上次采集成功的时间。从未成功过则为 nil。
    public var lastSuccessAt: Date?
    /// 最近一次采集的错误。成功时为 nil。
    public var lastError: String?
    /// 采集成功但需要提醒的情况（例如服务器时区不是 UTC）。
    public var warnings: [String]

    public init(
        server: ServerConfig,
        period: BillingPeriod,
        evaluatedAt: Date = Date(),
        usedGB: Double,
        quotaGB: Double,
        days: [DailyUsage],
        lastSuccessAt: Date? = nil,
        lastError: String? = nil,
        warnings: [String] = []
    ) {
        self.server = server
        self.period = period
        self.evaluatedAt = evaluatedAt
        self.usedGB = usedGB
        self.quotaGB = quotaGB
        self.days = days
        self.lastSuccessAt = lastSuccessAt
        self.lastError = lastError
        self.warnings = warnings
    }

    /// 已用比例（0…1+）。配额未知（<= 0）时返回 nil，UI 需据此显示"配额未知"而不是画进度条。
    public var usedFraction: Double? {
        guard quotaGB > 0 else { return nil }
        return usedGB / quotaGB
    }

    public var remainingGB: Double? {
        guard quotaGB > 0 else { return nil }
        return Swift.max(0, quotaGB - usedGB)
    }

    /// 账期剩余天数。
    public var remainingDays: Int {
        period.remainingDays(now: evaluatedAt)
    }

    /// 按当前平均速度外推到账期结束时的总用量（GB）。账期刚开始不足半天时返回 nil
    /// —— 此时样本太少，外推出来的数字会被瞬时波动放大到毫无参考价值。
    public var projectedGB: Double? {
        let elapsed = period.elapsedDays(now: evaluatedAt)
        guard elapsed >= 0.5 else { return nil }
        return usedGB / elapsed * Double(period.totalDays)
    }

    /// 按当前速度是否会超额。
    public var willExceed: Bool {
        guard quotaGB > 0, let projected = projectedGB else { return false }
        return projected > quotaGB
    }

    /// 严重程度，决定进度条与状态栏的配色。
    public enum Severity: Sendable {
        case normal, warning, critical, unknown
    }

    public var severity: Severity {
        guard let f = usedFraction else { return .unknown }
        if f >= 0.85 { return .critical }
        if f >= 0.70 { return .warning }
        return .normal
    }
}
