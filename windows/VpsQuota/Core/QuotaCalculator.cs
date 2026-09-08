namespace VpsQuota.Core;

using VpsQuota.Models;

/// <summary>
/// 把「按天的 rx/tx 序列」折算成「当前账期的用量结论」。
///
/// 这一层完全不关心数据从哪来 —— Vultr API 和 SSH+vnstat 走到这里已经归一了。
/// </summary>
public static class QuotaCalculator
{
    /// <summary>
    /// 按计费口径累加账期内的字节数。
    /// <paramref name="days"/> 允许包含账期外的数据（例如上游一次返回 30 天窗口），会在这里被过滤掉。
    /// </summary>
    public static long BilledBytes(IEnumerable<DailyUsage> days, MeterMode meterMode, BillingPeriod period)
    {
        long total = 0;
        foreach (var d in days)
        {
            if (!period.Contains(d.Day)) continue;
            total += meterMode.BilledBytes(d.RxBytes, d.TxBytes);
        }
        return total;
    }

    /// <summary>
    /// 生成供界面直接渲染的状态。
    /// </summary>
    /// <param name="apiQuotaGB">
    /// Vultr API 返回的 allowed_bandwidth。仅在 <c>server.QuotaGB &lt;= 0</c> 时作为配额来源，
    /// 让用户手填的值始终优先。
    /// </param>
    public static ServerStatus Status(
        ServerConfig server,
        IEnumerable<DailyUsage> days,
        DateTime now,
        double? apiQuotaGB = null,
        DateTime? lastSuccessAt = null,
        string? lastError = null,
        IReadOnlyList<string>? warnings = null)
    {
        var period = BillingPeriod.Current(server.ResetDay, now);
        var inPeriod = days
            .Where(d => period.Contains(d.Day))
            .OrderBy(d => d.Day, StringComparer.Ordinal)
            .ToList();

        var bytes = BilledBytes(inPeriod, server.MeterMode, period);
        var usedGB = bytes / server.UnitBase.BytesPerGB();

        // 用户显式填写的配额优先；填 0 时才回退到 API 报告的值。
        var quotaGB = server.QuotaGB > 0 ? server.QuotaGB : (apiQuotaGB ?? 0);

        return new ServerStatus
        {
            Server = server,
            Period = period,
            EvaluatedAt = now,
            UsedGB = usedGB,
            QuotaGB = quotaGB,
            Days = inPeriod,
            LastSuccessAt = lastSuccessAt,
            LastError = lastError,
            Warnings = warnings ?? Array.Empty<string>(),
        };
    }
}
