namespace VpsQuota.Tests;

using System.IO;
using System.Text.Json;
using VpsQuota.Collectors;
using VpsQuota.Models;
using Xunit;

/// <summary>
/// 搬瓦工采集器。KiwiVM 只给账期累计计数器，日流量靠「计数器差值」还原，
/// 这组测试把差值算法的每一种状态迁移钉死。
/// 与 macOS 端的 <c>BwgCollectorTests.swift</c> 逐条对应，期望值逐字相同。
/// </summary>
public class BwgCollectorTests
{
    // 差值算法

    [Fact(DisplayName = "首次观测：没有快照，整个计数器都记到当天")]
    public void FirstObservation()
    {
        var (days, snapshot) = BwgCollector.Derive(
            "2026-10-27", 5000, 1_793_491_200, null);

        var day = Assert.Single(days);
        Assert.Equal("2026-10-27", day.Day);
        Assert.Equal(0, day.RxBytes);
        Assert.Equal(5000, day.TxBytes);
        Assert.Equal(new BwgCollector.Snapshot("2026-10-27", 0, 5000, 1_793_491_200), snapshot);
    }

    [Fact(DisplayName = "同一天内多次观测是绝对重算：当天用量 = 计数器 − 当日基线，天然幂等")]
    public void SameDayIsAbsoluteRecompute()
    {
        var prev = new BwgCollector.Snapshot("2026-10-27", 1000, 2000, 1_793_491_200);

        var first = BwgCollector.Derive("2026-10-27", 3500, 1_793_491_200, prev);
        var firstDay = Assert.Single(first.Days);
        Assert.Equal(2500, firstDay.TxBytes);
        Assert.Equal(1000, first.Snapshot.DayStartCounter);

        // 再来一轮：基于上一轮的快照继续增长，仍然等于「计数器 − 基线」。
        var second = BwgCollector.Derive("2026-10-27", 4000, 1_793_491_200, first.Snapshot);
        var secondDay = Assert.Single(second.Days);
        Assert.Equal(3000, secondDay.TxBytes);
    }

    [Fact(DisplayName = "跨天：昨天最后一次观测值成为今天的基线，隔夜的增量记到今天")]
    public void DayRollover()
    {
        var prev = new BwgCollector.Snapshot("2026-10-27", 1000, 2000, 1_793_491_200);

        var (days, snapshot) = BwgCollector.Derive("2026-10-28", 2600, 1_793_491_200, prev);

        var day = Assert.Single(days);
        Assert.Equal("2026-10-28", day.Day);
        Assert.Equal(600, day.TxBytes);
        Assert.Equal(2000, snapshot.DayStartCounter);
    }

    [Fact(DisplayName = "计数器回落 → 换账期，基线归零，新计数器整体属于新账期")]
    public void CounterDropMeansNewCycle()
    {
        var prev = new BwgCollector.Snapshot("2026-10-27", 1000, 9000, 1_793_491_200);

        var (days, snapshot) = BwgCollector.Derive("2026-10-27", 50, 1_803_808_800, prev);

        var day = Assert.Single(days);
        Assert.Equal(50, day.TxBytes);
        Assert.Equal(0, snapshot.DayStartCounter);
    }

    [Fact(DisplayName = "nextReset 变化也识别换账期 —— 防止重置后一个周期内又涨回旧值时被漏判")]
    public void NextResetChangeMeansNewCycle()
    {
        var prev = new BwgCollector.Snapshot("2026-10-27", 1000, 9000, 1_793_491_200);

        // 计数器比旧账期结束时的还大（新账期跑得比旧账期整个月还多），仅靠回落检测不出来。
        var (days, _) = BwgCollector.Derive("2026-10-27", 9500, 1_803_808_800, prev);

        var day = Assert.Single(days);
        Assert.Equal(9500, day.TxBytes);
    }

    [Fact(DisplayName = "计数器没动：当天写 0，不报错也不累加")]
    public void IdleCounter()
    {
        var prev = new BwgCollector.Snapshot("2026-10-27", 2000, 2000, 1_793_491_200);

        var (days, snapshot) = BwgCollector.Derive("2026-10-27", 2000, 1_793_491_200, prev);

        var day = Assert.Single(days);
        Assert.Equal(0, day.TxBytes);
        Assert.Equal(2000, snapshot.Counter);
    }

    // 口径折算

    [Fact(DisplayName = "官方口径：计数器与配额都要乘 monthly_data_multiplier")]
    public void MultiplierAppliesToBothCounterAndQuota()
    {
        // 16 GiB × 2.5 = 40 GiB
        Assert.Equal(42_949_672_960L, BwgCollector.BilledBytes(17_179_869_184, 2.5));
        // 缺省系数按 1 处理（老套餐/未返回该字段）
        Assert.Equal(17_179_869_184L, BwgCollector.BilledBytes(17_179_869_184, 1));
    }

    // 响应解析

    [Fact(DisplayName = "解析 getServiceInfo 响应：suspended 是 0/1 数字也能读")]
    public void ParsesServiceInfo()
    {
        const string json = """
        {
          "vm_type": "kvm", "veid": 2234494, "hostname": "bwg-lax",
          "node_location": "Los Angeles, California", "plan": "CN2GIA_512M",
          "plan_monthly_data": 42949672960, "monthly_data_multiplier": 2.5,
          "data_counter": 17179869184, "data_next_reset": 1794830400,
          "suspended": 0, "error": 0
        }
        """;

        var parsed = JsonSerializer.Deserialize<BwgCollector.ServiceInfoResponse>(json);

        Assert.NotNull(parsed);
        Assert.Equal(0, parsed!.Error);
        Assert.Equal(42_949_672_960L, parsed.PlanMonthlyData);
        Assert.Equal(17_179_869_184L, parsed.DataCounter);
        Assert.Equal(2.5, parsed.MonthlyDataMultiplier);
        Assert.Equal(1_794_830_400L, parsed.DataNextReset);
        Assert.False(parsed.Suspended);
    }

    [Fact(DisplayName = "suspended 的布尔写法（true/false）同样能读")]
    public void ParsesBooleanSuspended()
    {
        const string json = """{ "error": 0, "data_counter": 1, "suspended": true }""";

        var parsed = JsonSerializer.Deserialize<BwgCollector.ServiceInfoResponse>(json);

        Assert.NotNull(parsed);
        Assert.True(parsed!.Suspended);
    }

    [Fact(DisplayName = "error 非 0 时把上游 message 原样透出")]
    public void ApiErrorMessage()
    {
        var ex = Assert.Throws<CollectException>(
            () => BwgCollector.ThrowIfApiError(
                new BwgCollector.ServiceInfoResponse { Error = 3, Message = "Invalid API key" }));

        Assert.Contains("error 3", ex.Message);
        Assert.Contains("Invalid API key", ex.Message);
        Assert.Contains("VEID", ex.Message);
    }

    // 重置日校验

    [Fact(DisplayName = "重置日校验：一致、不一致、月末钳制与缺时间戳")]
    public void ResetDayValidation()
    {
        // 1_794_830_400 = 2026-11-16 12:00 UTC → 每月 16 号重置
        Assert.Null(BwgCollector.ResetDayMismatch(16, 1_794_830_400));
        var mismatch = BwgCollector.ResetDayMismatch(21, 1_794_830_400);
        Assert.NotNull(mismatch);
        Assert.Equal((16, 21), (mismatch!.Value.Actual, mismatch.Value.Expected));

        // 1_803_808_800 = 2027-02-28 10:00 UTC（平年二月末）：配置 31 号按月末钳制，视为一致
        Assert.Null(BwgCollector.ResetDayMismatch(31, 1_803_808_800));
        // 配置 5 号则真的不一致
        var february = BwgCollector.ResetDayMismatch(5, 1_803_808_800);
        Assert.NotNull(february);
        Assert.Equal((28, 5), (february!.Value.Actual, february.Value.Expected));

        // 上游没给时间戳就无从校验
        Assert.Null(BwgCollector.ResetDayMismatch(16, 0));
    }

    // 快照文件

    [Fact(DisplayName = "快照按 VEID 独立落盘，读不回来按首次观测处理")]
    public void StateStoreRoundTrip()
    {
        var dir = Path.Combine(Path.GetTempPath(), "bwg-test-" + Guid.NewGuid().ToString("N"));
        try
        {
            var store = new BwgStateStore(dir);
            var snapshot = new BwgCollector.Snapshot("2026-10-27", 100, 200, 1_793_491_200);

            store.Save("2234494", snapshot);
            Assert.Equal(snapshot, store.Load("2234494"));

            // 另一个 VEID 互不干扰
            Assert.Null(store.Load("999999"));

            // 文件名里的非法字符被替换，VEID 出不了目录（"." 和 "/" 都不是字母数字）
            Assert.Equal("---evil.json", Path.GetFileName(store.FilePath("../evil")));
        }
        finally
        {
            try { Directory.Delete(dir, recursive: true); }
            catch (IOException) { }
        }
    }
}
