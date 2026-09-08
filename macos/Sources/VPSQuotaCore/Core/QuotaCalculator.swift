import Foundation

/// 把「按天的 rx/tx 序列」折算成「当前账期的用量结论」。
///
/// 这一层完全不关心数据从哪来 —— Vultr API 和 SSH+vnstat 走到这里已经归一了。
public enum QuotaCalculator {

    /// 按计费口径累加账期内的字节数。
    ///
    /// `days` 允许包含账期外的数据（例如上游一次返回 30 天窗口），会在这里被过滤掉。
    public static func billedBytes(
        days: [DailyUsage],
        meterMode: MeterMode,
        period: BillingPeriod
    ) -> Int64 {
        days.reduce(Int64(0)) { acc, d in
            guard period.contains(day: d.day) else { return acc }
            return acc &+ meterMode.billedBytes(rx: d.rxBytes, tx: d.txBytes)
        }
    }

    /// 生成供 UI 直接渲染的状态。
    ///
    /// - Parameters:
    ///   - days: 任意区间的日流量，会按账期过滤并升序排序
    ///   - apiQuotaGB: Vultr API 返回的 `allowed_bandwidth`。仅在
    ///     `server.quotaGB <= 0` 时作为配额来源，让用户手填的值始终优先。
    public static func status(
        server: ServerConfig,
        days: [DailyUsage],
        now: Date = Date(),
        apiQuotaGB: Double? = nil,
        lastSuccessAt: Date? = nil,
        lastError: String? = nil,
        warnings: [String] = []
    ) -> ServerStatus {
        let period = BillingPeriod.current(resetDay: server.resetDay, now: now)
        let inPeriod = days
            .filter { period.contains(day: $0.day) }
            .sorted { $0.day < $1.day }

        let bytes = billedBytes(days: inPeriod, meterMode: server.meterMode, period: period)
        let usedGB = Double(bytes) / server.unitBase.bytesPerGB

        // 用户显式填写的配额优先；填 0 时才回退到 API 报告的值。
        let quotaGB = server.quotaGB > 0 ? server.quotaGB : (apiQuotaGB ?? 0)

        return ServerStatus(
            server: server,
            period: period,
            evaluatedAt: now,
            usedGB: usedGB,
            quotaGB: quotaGB,
            days: inPeriod,
            lastSuccessAt: lastSuccessAt,
            lastError: lastError,
            warnings: warnings
        )
    }
}
