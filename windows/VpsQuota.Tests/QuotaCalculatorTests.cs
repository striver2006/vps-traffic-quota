namespace VpsQuota.Tests;

using VpsQuota.Core;
using VpsQuota.Models;
using Xunit;

/// <summary>
/// 配额折算（需求 K2–K7）。用例与 macOS 端的 <c>QuotaCalculatorTests.swift</c> 一一对应，
/// 期望值逐字相同 —— 这正是验收标准第 6 条要保证的事。
/// </summary>
public class QuotaCalculatorTests
{
    private const long OneGiB = 1_073_741_824;

    private static DateTime Utc(int y, int m, int d, int h = 12) =>
        new(y, m, d, h, 0, 0, DateTimeKind.Utc);

    /// <summary>9 月 1–3 日：rx 合计 3 GiB，tx 合计 6 GiB。另含一条账期外的数据用于验证过滤。</summary>
    private static readonly List<DailyUsage> Sample = new()
    {
        new DailyUsage("2026-08-31", 99 * OneGiB, 99 * OneGiB),
        new DailyUsage("2026-09-01", 1 * OneGiB, 2 * OneGiB),
        new DailyUsage("2026-09-02", 1 * OneGiB, 3 * OneGiB),
        new DailyUsage("2026-09-03", 1 * OneGiB, 1 * OneGiB),
    };

    private static ServerConfig Server(MeterMode mode, double quotaGB = 100) => new()
    {
        Id = "s1",
        Name = "测试",
        Provider = ProviderKind.Ssh,
        QuotaGB = quotaGB,
        MeterMode = mode,
        ResetDay = 1,
    };

    [Theory(DisplayName = "四种计费口径分别得到正确的用量")]
    [InlineData(MeterMode.Outbound, 6.0)]
    [InlineData(MeterMode.Inbound, 3.0)]
    [InlineData(MeterMode.Sum, 9.0)]
    [InlineData(MeterMode.Max, 6.0)]   // 逐日取大者：2 + 3 + 1
    public void MeterModes(MeterMode mode, double expectedGB)
    {
        var status = QuotaCalculator.Status(Server(mode), Sample, Utc(2026, 9, 8));
        Assert.Equal(expectedGB, status.UsedGB, 3);
    }

    [Fact(DisplayName = "账期外的数据被排除")]
    public void ExcludesOutOfPeriod()
    {
        var status = QuotaCalculator.Status(Server(MeterMode.Sum), Sample, Utc(2026, 9, 8));
        Assert.True(status.UsedGB < 10);   // 8-31 那条 198 GiB 若被计入会远超 9
        Assert.Equal(3, status.Days.Count);
        Assert.Equal("2026-09-01", status.Days[0].Day);
    }

    [Fact(DisplayName = "十进制 GB 进制下的用量比二进制大 7.4%")]
    public void DecimalUnitBase()
    {
        var server = Server(MeterMode.Outbound);
        server.UnitBase = UnitBase.Decimal;
        var status = QuotaCalculator.Status(server, Sample, Utc(2026, 9, 8));
        // 6 GiB = 6442450944 字节 = 6.442 “十进制 GB”
        Assert.Equal(6.442450944, status.UsedGB, 3);
    }

    [Fact(DisplayName = "用户手填的配额优先于 API 报告的值")]
    public void ManualQuotaWins()
    {
        var status = QuotaCalculator.Status(
            Server(MeterMode.Outbound, 500), Sample, Utc(2026, 9, 8), apiQuotaGB: 1000);
        Assert.Equal(500, status.QuotaGB);
    }

    [Fact(DisplayName = "配额填 0 时回退到 API 报告的值")]
    public void FallsBackToApiQuota()
    {
        var status = QuotaCalculator.Status(
            Server(MeterMode.Outbound, 0), Sample, Utc(2026, 9, 8), apiQuotaGB: 1000);
        Assert.Equal(1000, status.QuotaGB);
    }

    [Fact(DisplayName = "配额完全未知时不计算比例，而不是当成 0")]
    public void UnknownQuotaYieldsNull()
    {
        var status = QuotaCalculator.Status(Server(MeterMode.Outbound, 0), Sample, Utc(2026, 9, 8));
        Assert.Equal(0, status.QuotaGB);
        Assert.Null(status.UsedFraction);
        Assert.Null(status.RemainingGB);
        Assert.Equal(Severity.Unknown, status.Severity);
        Assert.False(status.WillExceed);
    }

    [Theory(DisplayName = "严重程度阈值：70% 转黄，85% 转红")]
    [InlineData(69.9, Severity.Normal)]
    [InlineData(70.0, Severity.Warning)]
    [InlineData(84.9, Severity.Warning)]
    [InlineData(85.0, Severity.Critical)]
    public void SeverityThresholds(double usedGB, Severity expected)
    {
        var status = new ServerStatus
        {
            Server = Server(MeterMode.Outbound),
            Period = BillingPeriod.Current(1, Utc(2026, 9, 8)),
            EvaluatedAt = Utc(2026, 9, 8),
            UsedGB = usedGB,
            QuotaGB = 100,
            Days = Array.Empty<DailyUsage>(),
        };
        Assert.Equal(expected, status.Severity);
    }

    [Fact(DisplayName = "按当前速度外推账期总用量")]
    public void Projection()
    {
        // 账期 9-01 起共 30 天；到 9-08 12:00 已过 7.5 天，用掉 6 GB
        var status = QuotaCalculator.Status(
            Server(MeterMode.Outbound, 100), Sample, Utc(2026, 9, 8));
        Assert.NotNull(status.ProjectedGB);
        Assert.Equal(6.0 / 7.5 * 30, status.ProjectedGB!.Value, 2);   // = 24
        Assert.False(status.WillExceed);
    }

    [Fact(DisplayName = "外推超过配额时给出超额判定")]
    public void ProjectionExceeds()
    {
        var status = QuotaCalculator.Status(
            Server(MeterMode.Outbound, 20), Sample, Utc(2026, 9, 8));
        Assert.True(status.WillExceed);   // 外推 24 GB > 配额 20 GB
    }

    [Fact(DisplayName = "账期开始不足半天时不做外推，避免被瞬时值放大")]
    public void NoProjectionTooEarly()
    {
        var status = QuotaCalculator.Status(
            Server(MeterMode.Outbound, 100),
            new[] { new DailyUsage("2026-09-01", 0, OneGiB) },
            Utc(2026, 9, 1, 2));
        Assert.Null(status.ProjectedGB);
        Assert.False(status.WillExceed);
    }

    [Fact(DisplayName = "恰好半天时开始给出外推值")]
    public void ProjectionAtExactlyHalfDay()
    {
        // K5 的边界就是 elapsed >= 0.5。这一行最容易在两端之间写反，
        // 所以两边都要把「恰好 0.5」钉住，而不只是测「不足半天」。
        var status = QuotaCalculator.Status(
            Server(MeterMode.Outbound, 100),
            new[] { new DailyUsage("2026-09-01", 0, OneGiB) },
            Utc(2026, 9, 1, 12));
        Assert.NotNull(status.ProjectedGB);
        Assert.Equal(1.0 / 0.5 * 30, status.ProjectedGB!.Value, 2);
    }

    [Fact(DisplayName = "剩余量不会出现负数")]
    public void RemainingNeverNegative()
    {
        var status = new ServerStatus
        {
            Server = Server(MeterMode.Outbound, 10),
            Period = BillingPeriod.Current(1, Utc(2026, 9, 8)),
            EvaluatedAt = Utc(2026, 9, 8),
            UsedGB = 25,
            QuotaGB = 10,
            Days = Array.Empty<DailyUsage>(),
        };
        Assert.Equal(0, status.RemainingGB);
    }
}
