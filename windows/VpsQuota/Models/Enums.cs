namespace VpsQuota.Models;

using System.Text.Json;
using System.Text.Json.Serialization;

/// <summary>
/// 服务商统计流量的口径。
///
/// 各家差异很大，且同一家不同套餐也可能不同，所以做成 per-server 配置而不写死：
/// Vultr 通常按出站计费；DMIT 分单向（出站）和双向套餐。
/// </summary>
[JsonConverter(typeof(MeterModeConverter))]
public enum MeterMode
{
    /// <summary>只统计出站流量（tx）</summary>
    Outbound,
    /// <summary>只统计入站流量（rx）</summary>
    Inbound,
    /// <summary>进出双向相加</summary>
    Sum,
    /// <summary>取进、出中较大的一方</summary>
    Max,
}

/// <summary>
/// 服务商在展示配额时使用的 "GB" 进制。
///
/// 1024³ 与 1000³ 相差 7.4%，在用量逼近 90% 时足以造成误判，
/// 而各家口径不统一也几乎不写在文档里，所以交给用户按面板数值校准。
/// </summary>
[JsonConverter(typeof(UnitBaseConverter))]
public enum UnitBase
{
    /// <summary>1 GB = 1024³ 字节</summary>
    Binary,
    /// <summary>1 GB = 1000³ 字节</summary>
    Decimal,
}

/// <summary>服务器的数据来源类型。</summary>
[JsonConverter(typeof(ProviderKindConverter))]
public enum ProviderKind
{
    /// <summary>通过 Vultr 官方 REST API 采集</summary>
    Vultr,
    /// <summary>通过 SSH 执行 vnstat 采集（DMIT 及任何没有 API 的服务商都走这条）</summary>
    Ssh,
}

/// <summary>用量的严重程度，决定进度条与托盘图标的配色。</summary>
public enum Severity
{
    Normal,
    Warning,
    Critical,
    Unknown,
}

/// <summary>
/// 枚举一律以 camelCase 字符串出入 JSON（outbound / binary / vultr …），
/// 与 macOS 端 Swift 的 RawValue 完全一致 —— 两端的 config.json 因此可以直接互换。
/// 默认的 PascalCase 会写出 "Outbound"，macOS 端读不出来。
/// </summary>
public sealed class MeterModeConverter : JsonStringEnumConverter<MeterMode>
{
    public MeterModeConverter() : base(JsonNamingPolicy.CamelCase) { }
}

public sealed class UnitBaseConverter : JsonStringEnumConverter<UnitBase>
{
    public UnitBaseConverter() : base(JsonNamingPolicy.CamelCase) { }
}

public sealed class ProviderKindConverter : JsonStringEnumConverter<ProviderKind>
{
    public ProviderKindConverter() : base(JsonNamingPolicy.CamelCase) { }
}

public static class EnumExtensions
{
    /// <summary>按本口径把一天的 rx/tx 折算成计费字节数。</summary>
    public static long BilledBytes(this MeterMode mode, long rx, long tx) => mode switch
    {
        MeterMode.Outbound => tx,
        MeterMode.Inbound => rx,
        MeterMode.Sum => rx + tx,
        MeterMode.Max => Math.Max(rx, tx),
        _ => tx,
    };

    public static string DisplayName(this MeterMode mode) => mode switch
    {
        MeterMode.Outbound => "仅出站（单向）",
        MeterMode.Inbound => "仅入站",
        MeterMode.Sum => "进出双向相加",
        MeterMode.Max => "取进出较大者",
        _ => mode.ToString(),
    };

    public static double BytesPerGB(this UnitBase unit) => unit switch
    {
        UnitBase.Binary => 1_073_741_824d,   // 1024³
        UnitBase.Decimal => 1_000_000_000d,  // 1000³
        _ => 1_073_741_824d,
    };

    public static string DisplayName(this UnitBase unit) => unit switch
    {
        UnitBase.Binary => "1 GB = 1024³ 字节",
        UnitBase.Decimal => "1 GB = 1000³ 字节",
        _ => unit.ToString(),
    };

    public static string DisplayName(this ProviderKind provider) => provider switch
    {
        ProviderKind.Vultr => "Vultr API",
        ProviderKind.Ssh => "SSH + vnstat",
        _ => provider.ToString(),
    };
}
