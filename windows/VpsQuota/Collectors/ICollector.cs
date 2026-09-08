namespace VpsQuota.Collectors;

using VpsQuota.Models;

/// <summary>
/// 采集结果。
///
/// 除了日流量，Vultr 还能顺带报告实例的 allowed_bandwidth，
/// 用户没手填配额时就用它，所以这里一并带出来。
/// </summary>
public sealed class CollectResult
{
    public required IReadOnlyList<DailyUsage> Days { get; init; }

    /// <summary>上游报告的月配额（GB）。SSH 采集拿不到，恒为 null。</summary>
    public double? ReportedQuotaGB { get; init; }

    /// <summary>采集成功但有值得提醒的情况（例如服务器时区不是 UTC，导致日切分有偏差）。</summary>
    public IReadOnlyList<string> Warnings { get; init; } = Array.Empty<string>();
}

/// <summary>
/// 采集器：把某个服务商的数据统一成按天的 rx/tx 序列。
///
/// 这是全应用唯一需要按服务商分别实现的部分。往下（存储、账期折算、界面）
/// 都不再区分数据来源，新增服务商只要多写一个实现。
/// </summary>
public interface ICollector
{
    /// <param name="since">
    /// 需要覆盖到的最早 UTC 日期（含）。实现可以返回更多天，多出的部分会在账期折算时被过滤掉。
    /// </param>
    Task<CollectResult> FetchAsync(ServerConfig server, DateTime since, CancellationToken ct = default);
}

/// <summary>采集过程中的可预期错误。消息直接呈现给用户，所以必须写清楚怎么修。</summary>
public sealed class CollectException : Exception
{
    public CollectException(string message) : base(message) { }

    public static CollectException Misconfigured(string detail) =>
        new($"配置不完整：{detail}");

    public static CollectException Http(int status, string body)
    {
        var trimmed = body.Trim();
        var detail = trimmed.Length == 0
            ? ""
            : "：" + trimmed[..Math.Min(trimmed.Length, 300)];
        return new CollectException($"HTTP {status}{detail}");
    }

    public static CollectException Decode(string detail) =>
        new($"无法解析返回数据：{detail}");

    /// <summary>
    /// 原样透出 stderr —— SSH 的报错（Permission denied / Host key 变更 / command not found）
    /// 是排查问题的全部线索，绝不能吞掉。
    /// </summary>
    public static CollectException CommandFailed(string command, int exitCode, string stderr) =>
        new($"命令执行失败（退出码 {exitCode}）：{command}\n{stderr.Trim()}");

    public static CollectException NoData(string detail) => new(detail);
}
