namespace VpsQuota.Tests;

using System.IO;
using System.Runtime.CompilerServices;
using System.Text.Json;
using VpsQuota.Core;
using VpsQuota.Models;
using VpsQuota.Storage;
using Xunit;

/// <summary>
/// 跨端配置格式（需求 G2、验收标准第 2 条：config.json 拷过去要能直接用）。
/// </summary>
/// <remarks>
/// 与 macOS 端的 <c>CrossPlatformConfigTests.swift</c> 对应。两边都读同一份
/// <c>shared/config.example.json</c>，任何一端改了字段名或默认值，对面就会红。
/// </remarks>
public class CrossPlatformConfigTests
{
    private static string RepoRoot([CallerFilePath] string? thisFile = null)
    {
        var directory = Path.GetDirectoryName(thisFile)!;
        return Path.GetFullPath(Path.Combine(directory, "..", ".."));
    }

    private static AppConfig LoadExample() =>
        new ConfigStore(Path.Combine(RepoRoot(), "shared", "config.example.json")).Load();

    [Fact(DisplayName = "示例配置文件本身能被解析")]
    public void ExampleParses()
    {
        var config = LoadExample();

        Assert.Equal(60, config.RefreshIntervalMinutes);
        Assert.Equal("dmit-lax", config.MenuBarServerId);
        Assert.True(config.MenuBarShowsRemaining);
        Assert.Equal(2, config.Servers.Count);
    }

    [Fact(DisplayName = "枚举一律解析自小写字符串，与 macOS 端的 RawValue 一致")]
    public void EnumsUseCamelCase()
    {
        var config = LoadExample();

        var vultr = config.Servers.Single(s => s.Id == "vultr-singapore");
        Assert.Equal(ProviderKind.Vultr, vultr.Provider);
        Assert.Equal(MeterMode.Outbound, vultr.MeterMode);
        Assert.Equal(UnitBase.Binary, vultr.UnitBase);

        var dmit = config.Servers.Single(s => s.Id == "dmit-lax");
        Assert.Equal(ProviderKind.Ssh, dmit.Provider);
        Assert.Equal(MeterMode.Sum, dmit.MeterMode);
        Assert.Equal(10, dmit.ResetDay);
        Assert.Equal("eth0", dmit.Interface);
        Assert.Equal(22, dmit.SshPort);
    }

    [Fact(DisplayName = "能读入带起始已用量基准的配置")]
    public void ReadsUsageBaseline()
    {
        var dmit = LoadExample().Servers.Single(s => s.Id == "dmit-lax");

        Assert.NotNull(dmit.UsageBaseline);
        Assert.Equal("2026-09-10", dmit.UsageBaseline!.PeriodStart);
        Assert.Equal(320.5, dmit.UsageBaseline.UsedGB);
    }

    [Fact(DisplayName = "写出的 JSON 用驼峰字段名，且不含 null")]
    public void WritesCamelCaseWithoutNulls()
    {
        var path = Path.Combine(Path.GetTempPath(), "vpsquota-cfg-" + Guid.NewGuid().ToString("n") + ".json");
        var store = new ConfigStore(path);

        store.Save(new AppConfig
        {
            RefreshIntervalMinutes = 60,
            Servers = new List<ServerConfig>
            {
                new()
                {
                    Id = "s1", Name = "测试", Provider = ProviderKind.Ssh,
                    QuotaGB = 1000, MeterMode = MeterMode.Sum, ResetDay = 10,
                },
            },
        });

        var json = File.ReadAllText(path);
        try { File.Delete(path); } catch (IOException) { }

        Assert.Contains("\"refreshIntervalMinutes\"", json);
        Assert.Contains("\"quotaGB\"", json);
        Assert.Contains("\"meterMode\": \"sum\"", json);
        Assert.Contains("\"provider\": \"ssh\"", json);

        // Swift 的 JSONEncoder 省略 nil。这边若写出 null，
        // 不但两端产物不是同一份文本，自己下次读还会因为非 nullable 值类型而抛异常。
        Assert.DoesNotContain("null", json);
        // menuBarServerId 没指定，不该出现在文件里
        Assert.DoesNotContain("menuBarServerId", json);
    }

    [Fact(DisplayName = "缺必填字段的条目被跳过，其余服务器仍然可用")]
    public void SkipsBrokenEntries()
    {
        var json = """
        {
          "refreshIntervalMinutes": 60,
          "servers": [
            { "id": "ok-1", "name": "正常", "provider": "ssh", "quotaGB": 1000 },
            { "name": "缺 id 和 provider", "quotaGB": 500 },
            { "id": "ok-2", "name": "也正常", "provider": "vultr" }
          ]
        }
        """;
        var path = Path.Combine(Path.GetTempPath(), "vpsquota-broken-" + Guid.NewGuid().ToString("n") + ".json");
        File.WriteAllText(path, json);

        var store = new ConfigStore(path);
        var config = store.Load();
        try { File.Delete(path); } catch (IOException) { }

        Assert.Equal(new[] { "ok-1", "ok-2" }, config.Servers.Select(s => s.Id));
        Assert.Equal(1, store.SkippedServerCount);
    }

    [Fact(DisplayName = "显式 null 的字段退回默认值")]
    public void ExplicitNullFallsBackToDefault()
    {
        var json = """
        {
          "refreshIntervalMinutes": 60,
          "servers": [
            {
              "id": "s1", "name": "测试", "provider": "ssh",
              "quotaGB": null, "resetDay": null, "unitBase": null,
              "sshPort": null, "usageBaseline": null
            }
          ]
        }
        """;
        var path = Path.Combine(Path.GetTempPath(), "vpsquota-null-" + Guid.NewGuid().ToString("n") + ".json");
        File.WriteAllText(path, json);

        var config = new ConfigStore(path).Load();
        try { File.Delete(path); } catch (IOException) { }

        var server = Assert.Single(config.Servers);
        Assert.Equal(0, server.QuotaGB);
        Assert.Equal(1, server.ResetDay);
        Assert.Equal(UnitBase.Binary, server.UnitBase);
        Assert.Null(server.SshPort);
        Assert.Null(server.UsageBaseline);
    }

    [Fact(DisplayName = "字段名区分大小写，与 macOS 端一样严格")]
    public void PropertyNamesAreCaseSensitive()
    {
        // {"Provider": …} 这种写法以前在 Windows 上能过、拷到 macOS 才炸。
        // 现在两端一样严格：provider 认不出来 → 视为缺必填字段 → 跳过该条目。
        var json = """
        { "servers": [ { "id": "s1", "name": "测试", "Provider": "ssh" } ] }
        """;
        var path = Path.Combine(Path.GetTempPath(), "vpsquota-case-" + Guid.NewGuid().ToString("n") + ".json");
        File.WriteAllText(path, json);

        var store = new ConfigStore(path);
        var config = store.Load();
        try { File.Delete(path); } catch (IOException) { }

        Assert.Empty(config.Servers);
        Assert.Equal(1, store.SkippedServerCount);
    }
}
