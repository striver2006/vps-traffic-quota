namespace VpsQuota.Tests;

using System.IO;
using VpsQuota.Models;
using VpsQuota.Storage;
using Xunit;

/// <summary>
/// 本地存储（需求 S1–S3）。与 macOS 端 <c>StoreTests.swift</c> 一一对应。
/// </summary>
public class SqliteStoreTests
{
    /// <summary>建一个临时库，用完连目录一起删。</summary>
    private sealed class TempStore : IAsyncDisposable
    {
        public SqliteStore Store { get; }
        private readonly string _directory;

        public TempStore()
        {
            _directory = Path.Combine(Path.GetTempPath(), "vpsquota-tests-" + Guid.NewGuid().ToString("n"));
            Store = new SqliteStore(Path.Combine(_directory, "usage.sqlite"));
        }

        public async ValueTask DisposeAsync()
        {
            await Store.DisposeAsync();
            try { Directory.Delete(_directory, recursive: true); }
            catch (IOException) { /* 临时目录删不掉不影响测试结论 */ }
        }
    }

    [Fact(DisplayName = "写入后能按区间读回，且左闭右开")]
    public async Task UpsertAndRange()
    {
        await using var temp = new TempStore();

        await temp.Store.UpsertAsync("s1", new[]
        {
            new DailyUsage("2026-08-31", 1, 1),
            new DailyUsage("2026-09-01", 10, 20),
            new DailyUsage("2026-09-02", 30, 40),
            new DailyUsage("2026-10-01", 9, 9),
        });

        var rows = await temp.Store.DaysAsync("s1", "2026-09-01", "2026-10-01");

        Assert.Equal(new[] { "2026-09-01", "2026-09-02" }, rows.Select(r => r.Day));
        Assert.Equal(10, rows[0].RxBytes);
        Assert.Equal(40, rows[1].TxBytes);
    }

    [Fact(DisplayName = "同一天再次写入是覆盖而非累加")]
    public async Task UpsertOverwrites()
    {
        await using var temp = new TempStore();

        await temp.Store.UpsertAsync("s1", new[] { new DailyUsage("2026-09-01", 10, 10) });
        // 当天的流量在一天之内会持续增长，第二次采集必须覆盖掉第一次的值
        await temp.Store.UpsertAsync("s1", new[] { new DailyUsage("2026-09-01", 50, 60) });

        var rows = await temp.Store.DaysAsync("s1", "2026-09-01", "2026-09-02");

        Assert.Single(rows);
        Assert.Equal(50, rows[0].RxBytes);
        Assert.Equal(60, rows[0].TxBytes);
    }

    [Fact(DisplayName = "不同服务器的数据互不干扰")]
    public async Task ServersAreIsolated()
    {
        await using var temp = new TempStore();

        await temp.Store.UpsertAsync("s1", new[] { new DailyUsage("2026-09-01", 1, 1) });
        await temp.Store.UpsertAsync("s2", new[] { new DailyUsage("2026-09-01", 2, 2) });

        var s1 = await temp.Store.DaysAsync("s1", "2026-09-01", "2026-09-02");

        Assert.Single(s1);
        Assert.Equal(1, s1[0].RxBytes);
    }

    [Fact(DisplayName = "空数组写入不报错")]
    public async Task EmptyUpsertIsFine()
    {
        await using var temp = new TempStore();
        await temp.Store.UpsertAsync("s1", Array.Empty<DailyUsage>());
        Assert.Empty(await temp.Store.DaysAsync("s1", "2026-01-01", "2027-01-01"));
    }

    [Fact(DisplayName = "只有成功的采集才更新最后成功时间")]
    public async Task LastSuccessOnlyTracksSuccess()
    {
        await using var temp = new TempStore();
        var early = new DateTime(2026, 9, 1, 10, 0, 0, DateTimeKind.Utc);
        var later = new DateTime(2026, 9, 2, 10, 0, 0, DateTimeKind.Utc);

        await temp.Store.LogFetchAsync("s1", early, ok: true, error: null);
        await temp.Store.LogFetchAsync("s1", later, ok: false, error: "连接超时");

        var last = await temp.Store.LastSuccessAsync("s1");

        Assert.NotNull(last);
        Assert.Equal(early, last!.Value);
    }

    [Fact(DisplayName = "从未成功过时返回 null")]
    public async Task LastSuccessIsNullWhenNeverSucceeded()
    {
        await using var temp = new TempStore();
        await temp.Store.LogFetchAsync("s1", DateTime.UtcNow, ok: false, error: "失败");
        Assert.Null(await temp.Store.LastSuccessAsync("s1"));
    }
}

/// <summary>
/// 上游元数据与错误的持久化（P5、S3）。与 macOS 端「元数据持久化」套件对应。
/// </summary>
/// <remarks>
/// 这两样以前只存在内存里：应用一重启，一台一直连不上的服务器会显示成"正常"，
/// 而 QuotaGB 填 0 的 Vultr 实例会显示成"配额未知"—— 直到第一轮采集跑完为止。
/// </remarks>
public class SqliteStoreMetaTests
{
    private sealed class TempStore : IAsyncDisposable
    {
        public SqliteStore Store { get; }
        private readonly string _directory;

        public TempStore()
        {
            _directory = Path.Combine(Path.GetTempPath(), "vpsquota-meta-" + Guid.NewGuid().ToString("n"));
            Store = new SqliteStore(Path.Combine(_directory, "usage.sqlite"));
        }

        public async ValueTask DisposeAsync()
        {
            await Store.DisposeAsync();
            try { Directory.Delete(_directory, recursive: true); } catch (IOException) { }
        }
    }

    [Fact(DisplayName = "上游报告的配额写入后能读回，且是覆盖式的")]
    public async Task ReportedQuotaRoundTrip()
    {
        await using var temp = new TempStore();

        Assert.Null(await temp.Store.ReportedQuotaAsync("s1"));

        await temp.Store.SetReportedQuotaAsync("s1", 2000);
        Assert.Equal(2000, await temp.Store.ReportedQuotaAsync("s1"));

        await temp.Store.SetReportedQuotaAsync("s1", 4000);
        Assert.Equal(4000, await temp.Store.ReportedQuotaAsync("s1"));
    }

    [Fact(DisplayName = "传 null 表示这次没拿到，不覆盖已有值")]
    public async Task NullQuotaDoesNotOverwrite()
    {
        await using var temp = new TempStore();

        await temp.Store.SetReportedQuotaAsync("s1", 2000);
        await temp.Store.SetReportedQuotaAsync("s1", null);
        Assert.Equal(2000, await temp.Store.ReportedQuotaAsync("s1"));
    }

    [Fact(DisplayName = "最近一次采集失败时读得到错误原因")]
    public async Task LastErrorAfterFailure()
    {
        await using var temp = new TempStore();
        var t0 = new DateTime(2026, 9, 1, 10, 0, 0, DateTimeKind.Utc);

        await temp.Store.LogFetchAsync("s1", t0, ok: true, error: null);
        await temp.Store.LogFetchAsync("s1", t0.AddMinutes(1), ok: false, error: "Permission denied");

        Assert.Equal("Permission denied", await temp.Store.LastErrorAsync("s1"));
    }

    [Fact(DisplayName = "最近一次成功时不再报旧错误")]
    public async Task LastErrorClearedBySuccess()
    {
        await using var temp = new TempStore();
        var t0 = new DateTime(2026, 9, 1, 10, 0, 0, DateTimeKind.Utc);

        await temp.Store.LogFetchAsync("s1", t0, ok: false, error: "Permission denied");
        await temp.Store.LogFetchAsync("s1", t0.AddMinutes(1), ok: true, error: null);

        Assert.Null(await temp.Store.LastErrorAsync("s1"));
    }

    [Fact(DisplayName = "从未采集过时没有错误")]
    public async Task LastErrorIsNullWhenNeverFetched()
    {
        await using var temp = new TempStore();
        Assert.Null(await temp.Store.LastErrorAsync("s1"));
    }
}
