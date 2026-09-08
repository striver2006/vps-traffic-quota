namespace VpsQuota.Models;

using System.Text.Json.Serialization;

/// <summary>
/// 一台被监控的服务器。
///
/// 与 macOS 端共用同一份 JSON schema，字段名不可随意改动 ——
/// config.json 可以在两台机器之间直接拷贝。
/// </summary>
public sealed class ServerConfig
{
    /// <summary>
    /// 本地唯一标识，同时作为 SQLite 中 daily_usage.server_id 的取值。
    /// 改动它会丢失历史数据。
    /// </summary>
    public string Id { get; set; } = "";

    public string Name { get; set; } = "";

    public ProviderKind Provider { get; set; } = ProviderKind.Ssh;

    /// <summary>月配额（GB）。Vultr 服务器填 0 表示自动采用 API 返回的 allowed_bandwidth。</summary>
    public double QuotaGB { get; set; }

    public MeterMode MeterMode { get; set; } = MeterMode.Outbound;

    /// <summary>每月账单重置日（1–31）。当月没有该日时按当月最后一天处理。</summary>
    public int ResetDay { get; set; } = 1;

    /// <summary>该服务商的 GB 进制。默认 Binary（1024³），首次接入时对照面板校准。</summary>
    public UnitBase UnitBase { get; set; } = UnitBase.Binary;

    // Vultr 专用
    public string? VultrInstanceId { get; set; }

    // SSH 专用
    public string? SshHost { get; set; }
    public int? SshPort { get; set; }
    public string? SshUser { get; set; }

    /// <summary>私钥路径，支持 ~ 开头。为空则交给 ssh 按其自身配置决定。</summary>
    public string? SshKeyPath { get; set; }

    /// <summary>vnstat 要统计的网卡名。为空则让 vnstat 用默认网卡。</summary>
    public string? Interface { get; set; }

    public ServerConfig Clone() => (ServerConfig)MemberwiseClone();
}

/// <summary>应用整体配置，对应 config.json 的顶层结构。</summary>
public sealed class AppConfig
{
    /// <summary>自动刷新周期（分钟）。UI 提供 15 / 60 / 360 / 1440 四档。</summary>
    public int RefreshIntervalMinutes { get; set; } = 60;

    public List<ServerConfig> Servers { get; set; } = new();
}

/// <summary>某台服务器在某一个 UTC 自然日内的流量。</summary>
/// <remarks>
/// 这是整个应用的中枢数据结构：两种采集器的唯一职责就是产出它的序列，
/// 之后所有计算（存储、账期切分、配额折算）都不再关心数据来自 API 还是 vnstat。
/// </remarks>
/// <param name="Day">UTC 日期，格式 yyyy-MM-dd</param>
public readonly record struct DailyUsage(string Day, long RxBytes, long TxBytes);
