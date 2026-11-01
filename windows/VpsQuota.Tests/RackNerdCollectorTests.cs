namespace VpsQuota.Tests;

using System.IO;
using VpsQuota.Collectors;
using Xunit;

public class RackNerdCollectorTests
{
    [Fact(DisplayName = "首次观测：没有快照，整个计数器都记到当天")]
    public void FirstObservation()
    {
        var (days, snapshot) = RackNerdCollector.Derive("2026-11-01", 50_000_000, null);

        var day = Assert.Single(days);
        Assert.Equal("2026-11-01", day.Day);
        Assert.Equal(0, day.RxBytes);
        Assert.Equal(50_000_000, day.TxBytes);
        Assert.Equal("2026-11-01", snapshot.DayKey);
        Assert.Equal(0, snapshot.DayStartCounter);
        Assert.Equal(50_000_000, snapshot.Counter);
    }

    [Fact(DisplayName = "同一天内多次观测是绝对重算：当天用量 = 计数器 − 当日基线，天然幂等")]
    public void SameDayIsAbsoluteRecompute()
    {
        var prev = new RackNerdCollector.Snapshot
        {
            DayKey = "2026-11-01",
            DayStartCounter = 10_000_000,
            Counter = 20_000_000,
        };

        var first = RackNerdCollector.Derive("2026-11-01", 35_000_000, prev);
        var firstDay = Assert.Single(first.Days);
        Assert.Equal(25_000_000, firstDay.TxBytes);
        Assert.Equal(10_000_000, first.Snapshot.DayStartCounter);

        var second = RackNerdCollector.Derive("2026-11-01", 40_000_000, first.Snapshot);
        var secondDay = Assert.Single(second.Days);
        Assert.Equal(30_000_000, secondDay.TxBytes);
    }

    [Fact(DisplayName = "跨天：昨天最后一次观测值成为今天的基线，隔夜的增量记到今天")]
    public void DayRollover()
    {
        var prev = new RackNerdCollector.Snapshot
        {
            DayKey = "2026-11-01",
            DayStartCounter = 10_000_000,
            Counter = 20_000_000,
        };

        var (days, snapshot) = RackNerdCollector.Derive("2026-11-02", 26_000_000, prev);

        var day = Assert.Single(days);
        Assert.Equal("2026-11-02", day.Day);
        Assert.Equal(6_000_000, day.TxBytes);
        Assert.Equal(20_000_000, snapshot.DayStartCounter);
    }

    [Fact(DisplayName = "计数器回落 → 换账期，基线归零，新计数器整体属于新账期")]
    public void CounterDropMeansNewCycle()
    {
        var prev = new RackNerdCollector.Snapshot
        {
            DayKey = "2026-11-01",
            DayStartCounter = 10_000_000,
            Counter = 90_000_000,
        };

        var (days, snapshot) = RackNerdCollector.Derive("2026-11-01", 50_000, prev);

        var day = Assert.Single(days);
        Assert.Equal(50_000, day.TxBytes);
        Assert.Equal(0, snapshot.DayStartCounter);
    }

    [Fact(DisplayName = "计数器没动：当天写 0，不报错也不累加")]
    public void IdleCounter()
    {
        var prev = new RackNerdCollector.Snapshot
        {
            DayKey = "2026-11-01",
            DayStartCounter = 20_000_000,
            Counter = 20_000_000,
        };

        var (days, snapshot) = RackNerdCollector.Derive("2026-11-01", 20_000_000, prev);

        var day = Assert.Single(days);
        Assert.Equal(0, day.TxBytes);
        Assert.Equal(20_000_000, snapshot.Counter);
    }

    [Fact(DisplayName = "快照按服务器 ID 独立落盘")]
    public void StateStorePersistence()
    {
        var tempDir = Path.Combine(Path.GetTempPath(), Path.GetRandomFileName());
        try
        {
            var store = new RackNerdStateStore(tempDir);
            var s = new RackNerdCollector.Snapshot
            {
                DayKey = "2026-11-01",
                DayStartCounter = 100,
                Counter = 500,
            };
            store.Save("rn-1", s);

            var loaded = store.Load("rn-1");
            Assert.NotNull(loaded);
            Assert.Equal(s.DayKey, loaded.DayKey);
            Assert.Equal(s.DayStartCounter, loaded.DayStartCounter);
            Assert.Equal(s.Counter, loaded.Counter);

            Assert.Null(store.Load("rn-2"));
        }
        finally
        {
            if (Directory.Exists(tempDir)) Directory.Delete(tempDir, true);
        }
    }
}
