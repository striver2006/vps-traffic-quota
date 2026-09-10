namespace VpsQuota.Tests;

using VpsQuota.Core;
using Xunit;

/// <summary>
/// 账期切分（需求 K1）。
/// </summary>
/// <remarks>
/// 用例与 macOS 端的 <c>BillingPeriodTests.swift</c> 一一对应，**期望值逐字相同**。
/// 验收标准第 6 条要求两端计算逻辑对同一份输入给出相同结果，而这件事此前
/// 只有 Swift 那一侧有测试保障。改动任一端的账期逻辑时，两边的用例都要跟着改。
/// </remarks>
public class BillingPeriodTests
{
    private static DateTime Utc(int y, int m, int d, int h = 12) =>
        new(y, m, d, h, 0, 0, DateTimeKind.Utc);

    [Fact(DisplayName = "重置日为 1 号时账期就是自然月")]
    public void ResetDayOne()
    {
        var p = BillingPeriod.Current(1, Utc(2026, 9, 8));
        Assert.Equal("2026-09-01", p.StartDay);
        Assert.Equal("2026-10-01", p.EndDayExclusive);
        Assert.Equal(30, p.TotalDays);
    }

    [Fact(DisplayName = "当前时间早于本月重置日时，账期属于上一个月")]
    public void BeforeResetDay()
    {
        var p = BillingPeriod.Current(15, Utc(2026, 9, 8));
        Assert.Equal("2026-08-15", p.StartDay);
        Assert.Equal("2026-09-15", p.EndDayExclusive);
    }

    [Fact(DisplayName = "恰好是重置日当天时，账期从当天开始")]
    public void OnResetDay()
    {
        var p = BillingPeriod.Current(15, Utc(2026, 9, 15, 0));
        Assert.Equal("2026-09-15", p.StartDay);
        Assert.Equal("2026-10-15", p.EndDayExclusive);
    }

    [Fact(DisplayName = "重置日 31 号遇到只有 30 天的月份，退化为当月最后一天")]
    public void ResetDay31InThirtyDayMonth()
    {
        var p = BillingPeriod.Current(31, Utc(2026, 9, 30, 6));
        Assert.Equal("2026-09-30", p.StartDay);
        Assert.Equal("2026-10-31", p.EndDayExclusive);
    }

    [Fact(DisplayName = "重置日 31 号遇到 2 月，退化为 2-28")]
    public void ResetDay31InFebruary()
    {
        var p = BillingPeriod.Current(31, Utc(2026, 2, 28, 6));
        Assert.Equal("2026-02-28", p.StartDay);
        Assert.Equal("2026-03-31", p.EndDayExclusive);
    }

    [Fact(DisplayName = "闰年 2 月按 29 天处理")]
    public void LeapYearFebruary()
    {
        var p = BillingPeriod.Current(30, Utc(2028, 2, 29, 6));
        Assert.Equal("2028-02-29", p.StartDay);
        Assert.Equal("2028-03-30", p.EndDayExclusive);
    }

    [Fact(DisplayName = "跨年时账期正确回退到上一年 12 月")]
    public void AcrossYearBoundary()
    {
        var p = BillingPeriod.Current(20, Utc(2026, 1, 5));
        Assert.Equal("2025-12-20", p.StartDay);
        Assert.Equal("2026-01-20", p.EndDayExclusive);
    }

    [Fact(DisplayName = "非法的重置日被钳制到 1…31")]
    public void ClampsOutOfRangeResetDay()
    {
        var low = BillingPeriod.Current(0, Utc(2026, 9, 8));
        Assert.Equal("2026-09-01", low.StartDay);

        // 99 被钳到 31，9 月无 31 日故取 9-30；此时 9-8 尚未到达，账期为 [8-31, 9-30)
        var high = BillingPeriod.Current(99, Utc(2026, 9, 8));
        Assert.Equal("2026-08-31", high.StartDay);
        Assert.Equal("2026-09-30", high.EndDayExclusive);
    }

    [Fact(DisplayName = "Contains 按左闭右开判定")]
    public void ContainsIsHalfOpen()
    {
        var p = BillingPeriod.Current(1, Utc(2026, 9, 8));
        Assert.True(p.Contains("2026-09-01"));
        Assert.True(p.Contains("2026-09-30"));
        Assert.False(p.Contains("2026-08-31"));
        Assert.False(p.Contains("2026-10-01"));
    }

    [Fact(DisplayName = "已过天数与剩余天数")]
    public void ElapsedAndRemaining()
    {
        var p = BillingPeriod.Current(1, Utc(2026, 9, 8));
        Assert.Equal(7.5, p.ElapsedDays(Utc(2026, 9, 8)), 2);
        Assert.Equal(23, p.RemainingDays(Utc(2026, 9, 8)));
    }

    [Fact(DisplayName = "已过天数被钳制在账期范围内")]
    public void ElapsedIsClamped()
    {
        var p = BillingPeriod.Current(1, Utc(2026, 9, 8));
        Assert.Equal(0, p.ElapsedDays(Utc(2026, 8, 20)));
        Assert.Equal(p.TotalDays, p.ElapsedDays(Utc(2026, 11, 1)));
    }

    [Fact(DisplayName = "重置日 29/30 在平年 2 月退化为 2-28")]
    public void ResetDay29And30InCommonYearFebruary()
    {
        var p29 = BillingPeriod.Current(29, Utc(2026, 2, 28, 6));
        Assert.Equal("2026-02-28", p29.StartDay);

        var p30 = BillingPeriod.Current(30, Utc(2026, 2, 28, 6));
        Assert.Equal("2026-02-28", p30.StartDay);
    }

    [Fact(DisplayName = "由已被钳制的锚点再回退一个月，仍落在正确的日子上")]
    public void ChainedClampingGoesBackCorrectly()
    {
        // 1 月中旬、重置日 31：本月锚点是 1-31，尚未到达，
        // 账期应为 [2025-12-31, 2026-01-31) —— 而不是被 2 月的 28 天带偏。
        var p = BillingPeriod.Current(31, Utc(2026, 1, 15));
        Assert.Equal("2025-12-31", p.StartDay);
        Assert.Equal("2026-01-31", p.EndDayExclusive);
    }
}

/// <summary>
/// DateTime.Kind 的防线。
/// </summary>
/// <remarks>
/// macOS 端的账期计算强制走 UTC Calendar，传什么进去都不会错。
/// C# 这边类型系统拦不住误传本地时刻，所以在入口显式换算，并用测试钉住。
/// </remarks>
public class BillingPeriodKindTests
{
    [Fact(DisplayName = "传入本地时刻与等价的 UTC 时刻得到同一个账期")]
    public void LocalAndUtcAgree()
    {
        var utc = new DateTime(2026, 9, 15, 0, 30, 0, DateTimeKind.Utc);
        var local = utc.ToLocalTime();   // Kind = Local，挂钟读数可能是前一天

        var fromUtc = BillingPeriod.Current(15, utc);
        var fromLocal = BillingPeriod.Current(15, local);

        Assert.Equal(fromUtc.StartDay, fromLocal.StartDay);
        Assert.Equal(fromUtc.EndDayExclusive, fromLocal.EndDayExclusive);
    }

    [Fact(DisplayName = "Unspecified 被当作 UTC，不按本地时区解释")]
    public void UnspecifiedIsTreatedAsUtc()
    {
        var unspecified = new DateTime(2026, 9, 15, 0, 30, 0, DateTimeKind.Unspecified);
        var utc = DateTime.SpecifyKind(unspecified, DateTimeKind.Utc);

        Assert.Equal(
            BillingPeriod.Current(15, utc).StartDay,
            BillingPeriod.Current(15, unspecified).StartDay);
    }

    [Fact(DisplayName = "已过天数同样不受 Kind 影响")]
    public void ElapsedDaysIgnoresKind()
    {
        var period = BillingPeriod.Current(1, new DateTime(2026, 9, 8, 12, 0, 0, DateTimeKind.Utc));
        var utc = new DateTime(2026, 9, 8, 12, 0, 0, DateTimeKind.Utc);

        Assert.Equal(period.ElapsedDays(utc), period.ElapsedDays(utc.ToLocalTime()), 6);
    }
}
