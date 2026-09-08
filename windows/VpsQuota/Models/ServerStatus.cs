namespace VpsQuota.Models;

using VpsQuota.Core;

/// <summary>一台服务器在当前账期内的用量结论，供界面直接渲染。</summary>
public sealed class ServerStatus
{
    public required ServerConfig Server { get; init; }

    /// <summary>当前账期区间。</summary>
    public required BillingPeriod Period { get; init; }

    /// <summary>
    /// 本次状态的求值时刻。外推与"剩余天数"都以它为准，
    /// 而不是各自去读墙上时钟 —— 否则同一个状态对象里的几个数字会互相对不上，也无法测试。
    /// </summary>
    public required DateTime EvaluatedAt { get; init; }

    /// <summary>按 MeterMode 折算后的已用量（GB）。</summary>
    public required double UsedGB { get; init; }

    /// <summary>实际生效的配额（GB）。Vultr 且 QuotaGB == 0 时来自 API 的 allowed_bandwidth。</summary>
    public required double QuotaGB { get; init; }

    /// <summary>账期内的每日明细，已按日期升序，用于画趋势图。</summary>
    public required IReadOnlyList<DailyUsage> Days { get; init; }

    /// <summary>上次采集成功的时间。从未成功过则为 null。</summary>
    public DateTime? LastSuccessAt { get; init; }

    /// <summary>最近一次采集的错误。成功时为 null。</summary>
    public string? LastError { get; init; }

    /// <summary>采集成功但需要提醒的情况（例如服务器时区不是 UTC）。</summary>
    public IReadOnlyList<string> Warnings { get; init; } = Array.Empty<string>();

    /// <summary>
    /// 已用比例（0…1+）。配额未知（&lt;= 0）时返回 null，
    /// 界面需据此显示"配额未知"而不是画一条 0% 的进度条。
    /// </summary>
    public double? UsedFraction => QuotaGB > 0 ? UsedGB / QuotaGB : null;

    public double? RemainingGB => QuotaGB > 0 ? Math.Max(0, QuotaGB - UsedGB) : null;

    public int RemainingDays => Period.RemainingDays(EvaluatedAt);

    /// <summary>
    /// 按当前平均速度外推到账期结束时的总用量（GB）。
    /// 账期刚开始不足半天时返回 null —— 此时样本太少，外推值会被瞬时波动放大到毫无参考价值。
    /// </summary>
    public double? ProjectedGB
    {
        get
        {
            var elapsed = Period.ElapsedDays(EvaluatedAt);
            if (elapsed < 0.5) return null;
            return UsedGB / elapsed * Period.TotalDays;
        }
    }

    /// <summary>按当前速度是否会超额。</summary>
    public bool WillExceed => QuotaGB > 0 && ProjectedGB is { } p && p > QuotaGB;

    public Severity Severity
    {
        get
        {
            if (UsedFraction is not { } f) return Severity.Unknown;
            if (f >= 0.85) return Severity.Critical;
            if (f >= 0.70) return Severity.Warning;
            return Severity.Normal;
        }
    }
}
