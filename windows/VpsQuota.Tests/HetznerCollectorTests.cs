namespace VpsQuota.Tests;

using System.IO;
using VpsQuota.Collectors;
using Xunit;

public class HetznerCollectorTests
{
    [Fact(DisplayName = "首次观测：没有快照，整个入出站计数器都记到当天")]
    public void FirstObservation()
    {
        var (days, snapshot) = HetznerCollector.Derive(
            "2026-11-01",
            "2026-11-01",
            30_000_000,
            10_000_000,
            null
        );

        var day = Assert.Single(days);
        Assert.Equal("2026-11-01", day.Day);
        Assert.Equal(10_000_000, day.RxBytes);
        Assert.Equal(30_000_000, day.TxBytes);
        Assert.Equal("2026-11-01", snapshot.DayKey);
        Assert.Equal(0, snapshot.DayStartTx);
        Assert.Equal(0, snapshot.DayStartRx);
        Assert.Equal(30_000_000, snapshot.TxCounter);
        Assert.Equal(10_000_000, snapshot.RxCounter);
        Assert.Equal("2026-11-01", snapshot.PeriodStart);
    }

    [Fact(DisplayName = "同一天多次观测：绝对重算出当日增量")]
    public void SameDayRecompute()
    {
        var prev = new HetznerCollector.Snapshot
        {
            DayKey = "2026-11-01",
            DayStartTx = 10_000_000,
            DayStartRx = 5_000_000,
            TxCounter = 25_000_000,
            RxCounter = 12_000_000,
            PeriodStart = "2026-11-01",
        };

        var (days, snapshot) = HetznerCollector.Derive(
            "2026-11-01",
            "2026-11-01",
            35_000_000,
            15_000_000,
            prev
        );

        var day = Assert.Single(days);
        Assert.Equal(10_000_000, day.RxBytes);
        Assert.Equal(25_000_000, day.TxBytes);
        Assert.Equal(10_000_000, snapshot.DayStartTx);
        Assert.Equal(5_000_000, snapshot.DayStartRx);
    }

    [Fact(DisplayName = "跨天：以昨日最终值作为今日基线")]
    public void DayRollover()
    {
        var prev = new HetznerCollector.Snapshot
        {
            DayKey = "2026-11-01",
            DayStartTx = 10_000_000,
            DayStartRx = 5_000_000,
            TxCounter = 25_000_000,
            RxCounter = 12_000_000,
            PeriodStart = "2026-11-01",
        };

        var (days, snapshot) = HetznerCollector.Derive(
            "2026-11-02",
            "2026-11-01",
            30_000_000,
            14_000_000,
            prev
        );

        var day = Assert.Single(days);
        Assert.Equal(2_000_000, day.RxBytes);
        Assert.Equal(5_000_000, day.TxBytes);
        Assert.Equal(25_000_000, snapshot.DayStartTx);
        Assert.Equal(12_000_000, snapshot.DayStartRx);
    }

    [Fact(DisplayName = "换账期：periodStart 变化或计数器回落时基线归零")]
    public void PeriodRollover()
    {
        var prev = new HetznerCollector.Snapshot
        {
            DayKey = "2026-10-31",
            DayStartTx = 20_000_000,
            DayStartRx = 10_000_000,
            TxCounter = 50_000_000,
            RxCounter = 25_000_000,
            PeriodStart = "2026-10-01",
        };

        var (days, snapshot) = HetznerCollector.Derive(
            "2026-11-01",
            "2026-11-01",
            2_000_000,
            1_000_000,
            prev
        );

        var day = Assert.Single(days);
        Assert.Equal(1_000_000, day.RxBytes);
        Assert.Equal(2_000_000, day.TxBytes);
        Assert.Equal(0, snapshot.DayStartTx);
        Assert.Equal(0, snapshot.DayStartRx);
    }

    [Fact(DisplayName = "快照落盘与加载")]
    public void StateStorePersistence()
    {
        var tempDir = Path.Combine(Path.GetTempPath(), Path.GetRandomFileName());
        try
        {
            var store = new HetznerStateStore(tempDir);
            var s = new HetznerCollector.Snapshot
            {
                DayKey = "2026-11-01",
                DayStartTx = 100,
                DayStartRx = 50,
                TxCounter = 200,
                RxCounter = 80,
                PeriodStart = "2026-11-01",
            };
            store.Save("hz-1", s);

            var loaded = store.Load("hz-1");
            Assert.NotNull(loaded);
            Assert.Equal(s.DayKey, loaded.DayKey);
            Assert.Equal(s.DayStartTx, loaded.DayStartTx);
            Assert.Equal(s.DayStartRx, loaded.DayStartRx);
            Assert.Equal(s.TxCounter, loaded.TxCounter);
            Assert.Equal(s.RxCounter, loaded.RxCounter);
            Assert.Equal(s.PeriodStart, loaded.PeriodStart);

            Assert.Null(store.Load("hz-2"));
        }
        finally
        {
            if (Directory.Exists(tempDir)) Directory.Delete(tempDir, true);
        }
    }
}
