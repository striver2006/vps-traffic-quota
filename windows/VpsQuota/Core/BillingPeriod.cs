namespace VpsQuota.Core;

/// <summary>
/// 一个账单周期，左闭右开：<c>[Start, End)</c>。
///
/// 服务商的流量额度按账单日重置，而账单日不一定是 1 号
/// （DMIT 通常是开通日，Vultr 是账号计费日），所以不能简单地按自然月统计。
/// </summary>
public readonly record struct BillingPeriod(DateTime Start, DateTime End)
{
    /// <summary>起点的 yyyy-MM-dd，可直接用于 SQLite 的 <c>day &gt;= ?</c>。</summary>
    public string StartDay => UtcDay.String(Start);

    /// <summary>终点的 yyyy-MM-dd（不含），可直接用于 SQLite 的 <c>day &lt; ?</c>。</summary>
    public string EndDayExclusive => UtcDay.String(End);

    public int TotalDays => (int)Math.Round((End - Start).TotalDays);

    /// <summary>账期已过去的天数（含小数）。超出账期时钳制到 [0, TotalDays]。</summary>
    public double ElapsedDays(DateTime now) =>
        Math.Clamp((ToUtc(now) - Start).TotalDays, 0, TotalDays);

    /// <summary>距账期结束还剩多少个完整日历天。</summary>
    public int RemainingDays(DateTime now) =>
        Math.Max(0, (int)Math.Round((End - UtcDay.StartOfDay(ToUtc(now))).TotalDays));

    /// <summary>判断某个 yyyy-MM-dd 是否落在本账期内。</summary>
    public bool Contains(string day) =>
        string.CompareOrdinal(day, StartDay) >= 0 &&
        string.CompareOrdinal(day, EndDayExclusive) < 0;

    /// <summary>
    /// 求出包含 <paramref name="now"/> 的账期。
    ///
    /// <paramref name="resetDay"/> 会被钳制到 1…31；当月天数不足时
    /// （例如 31 号遇上 2 月）取当月最后一天，这与主流服务商的做法一致。
    /// </summary>
    public static BillingPeriod Current(int resetDay, DateTime now)
    {
        // 账期一律按 UTC 切分（macOS 端由 UTC Calendar 强制保证）。
        // 这里传进来的必须是 UTC 时刻：本地时刻会让 UTC+8 的机器在当地 00:00–08:00
        // 把 now 算成前一天；若那天正好是重置日，now >= anchor 的判定翻转，
        // 整个账期回退一个月，已用量直接错一整期。类型系统拦不住，只能显式转。
        now = ToUtc(now);

        var clamped = Math.Clamp(resetDay, 1, 31);
        var thisMonthAnchor = Anchor(now, clamped);

        if (now >= thisMonthAnchor)
        {
            // 已过本月重置日：账期是 [本月重置日, 下月重置日)
            return new BillingPeriod(thisMonthAnchor, Anchor(thisMonthAnchor.AddMonths(1), clamped));
        }

        // 尚未到本月重置日：账期是 [上月重置日, 本月重置日)
        return new BillingPeriod(Anchor(thisMonthAnchor.AddMonths(-1), clamped), thisMonthAnchor);
    }

    /// <summary>
    /// 求 <paramref name="date"/> 所在自然月中的重置时刻（UTC 零点）。
    ///
    /// 当月天数不足 <paramref name="resetDay"/> 时退化为当月最后一天 ——
    /// 这是本函数存在的全部理由，也是 resetDay = 29/30/31 时唯一的正确处理方式。
    /// </summary>
    /// <summary>
    /// 统一成 UTC 时刻。Local 按时区换算；Unspecified 视作已经是 UTC
    /// （应用内的时间全部来自 DateTime.UtcNow 或本文件构造的 UTC 值）。
    /// </summary>
    private static DateTime ToUtc(DateTime value) => value.Kind switch
    {
        DateTimeKind.Utc => value,
        DateTimeKind.Local => value.ToUniversalTime(),
        _ => DateTime.SpecifyKind(value, DateTimeKind.Utc),
    };

    private static DateTime Anchor(DateTime date, int resetDay)
    {
        var daysInMonth = DateTime.DaysInMonth(date.Year, date.Month);
        var day = Math.Min(resetDay, daysInMonth);
        return new DateTime(date.Year, date.Month, day, 0, 0, 0, DateTimeKind.Utc);
    }
}
