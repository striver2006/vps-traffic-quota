namespace VpsQuota.Tests;

using VpsQuota.Core;
using VpsQuota.Models;
using Xunit;

/// <summary>
/// 起始已用量补偿（需求 K6）。与 macOS 端 <c>QuotaCalculatorTests.swift</c> 里的
/// 「起始已用量基准」套件一一对应。
/// </summary>
public class UsageBaselineTests
{
    private const long OneGiB = 1_073_741_824;

    private static DateTime Utc(int y, int m, int d, int h = 12) =>
        new(y, m, d, h, 0, 0, DateTimeKind.Utc);

    /// <summary>账期 8-10 → 9-10；采集到的只有 9-08 一天，2 GiB 出站。</summary>
    private static List<DailyUsage> Days => new()
    {
        new DailyUsage("2026-09-08", OneGiB, 2 * OneGiB),
    };

    private static ServerConfig Server(UsageBaseline? baseline) => new()
    {
        Id = "s1",
        Name = "DMIT",
        Provider = ProviderKind.Ssh,
        QuotaGB = 1000,
        MeterMode = MeterMode.Outbound,
        ResetDay = 10,
        UsageBaseline = baseline,
    };

    [Fact(DisplayName = "基准所属账期与当前账期一致时被计入")]
    public void AppliesToMatchingPeriod()
    {
        var status = QuotaCalculator.Status(
            Server(new UsageBaseline { PeriodStart = "2026-08-10", UsedGB = 300 }),
            Days, Utc(2026, 9, 8));

        Assert.Equal("2026-08-10", status.Period.StartDay);
        Assert.Equal(302, status.UsedGB, 3);   // 300 基准 + 2 GiB 实测
    }

    [Fact(DisplayName = "换到下一个账期后基准自动失效，不会凭空多出流量")]
    public void ExpiresOnNextPeriod()
    {
        var status = QuotaCalculator.Status(
            Server(new UsageBaseline { PeriodStart = "2026-08-10", UsedGB = 300 }),
            new[] { new DailyUsage("2026-09-12", 0, OneGiB) },
            Utc(2026, 9, 12));

        Assert.Equal("2026-09-10", status.Period.StartDay);
        Assert.Equal(1, status.UsedGB, 3);   // 只剩实测的 1 GiB，基准已失效
    }

    [Fact(DisplayName = "没有基准时行为不变")]
    public void NoBaseline()
    {
        var status = QuotaCalculator.Status(Server(null), Days, Utc(2026, 9, 8));
        Assert.Equal(2, status.UsedGB, 3);
    }

    [Fact(DisplayName = "基准为 0 视为未设置")]
    public void ZeroBaselineIsIgnored()
    {
        var status = QuotaCalculator.Status(
            Server(new UsageBaseline { PeriodStart = "2026-08-10", UsedGB = 0 }),
            Days, Utc(2026, 9, 8));
        Assert.Equal(2, status.UsedGB, 3);
    }

    [Fact(DisplayName = "基准计入后同样参与超额预测")]
    public void BaselineFeedsProjection()
    {
        var status = QuotaCalculator.Status(
            Server(new UsageBaseline { PeriodStart = "2026-08-10", UsedGB = 900 }),
            Days, Utc(2026, 9, 8));

        Assert.True(status.UsedGB > 900);
        Assert.Equal(Severity.Critical, status.Severity);   // 902/1000 > 85%
        Assert.NotNull(status.ProjectedGB);
        Assert.True(status.ProjectedGB!.Value > status.UsedGB);
    }
}
