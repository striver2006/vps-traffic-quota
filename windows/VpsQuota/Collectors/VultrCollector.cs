namespace VpsQuota.Collectors;

using System.Net.Http;
using System.Net.Http.Headers;
using System.Text.Json.Serialization;
using VpsQuota.Core;
using VpsQuota.Models;

/// <summary>
/// 通过 Vultr 官方 REST API v2 采集。
///
/// 用到两个端点：
/// <list type="bullet">
/// <item>GET /v2/instances —— 取 allowed_bandwidth（GB）作为配额来源</item>
/// <item>GET /v2/instances/{id}/bandwidth —— 取按天的 incoming_bytes / outgoing_bytes</item>
/// </list>
///
/// 注意：Vultr 官方明确说明带宽数据是<b>周期性刷新</b>的，不是实时值，
/// 因此没必要把刷新周期设得太短。日期键是 UTC，与本应用的存储口径一致，无需换算。
/// </summary>
public sealed class VultrCollector : ICollector
{
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(30) };

    private readonly string _apiKey;
    private readonly string _baseUrl;

    /// <summary>
    /// 实例 ID → 上游报告的配额（GB）。由调度层在一轮刷新开始时拉一次并传进来。
    /// 为 null 表示"自己去拉"，供单独调用的场景使用。
    /// </summary>
    private readonly IReadOnlyDictionary<string, double>? _quotaLookup;

    public VultrCollector(
        string apiKey,
        string baseUrl = "https://api.vultr.com/v2",
        IReadOnlyDictionary<string, double>? quotaLookup = null)
    {
        _apiKey = apiKey;
        _baseUrl = baseUrl.TrimEnd('/');
        _quotaLookup = quotaLookup;
    }

    // 响应模型

    private sealed class InstancesResponse
    {
        [JsonPropertyName("instances")]
        public List<Instance> Instances { get; set; } = new();

        /// <summary>分页游标。Vultr 一页最多 500 条，超过就要靠 meta.links.next 继续。</summary>
        [JsonPropertyName("meta")]
        public MetaInfo? Meta { get; set; }

        internal sealed class MetaInfo
        {
            [JsonPropertyName("links")] public LinksInfo? Links { get; set; }

            internal sealed class LinksInfo
            {
                [JsonPropertyName("next")] public string? Next { get; set; }
            }
        }

        internal sealed class Instance
        {
            [JsonPropertyName("id")] public string Id { get; set; } = "";
            [JsonPropertyName("label")] public string? Label { get; set; }
            [JsonPropertyName("region")] public string? Region { get; set; }
            [JsonPropertyName("main_ip")] public string? MainIp { get; set; }
            [JsonPropertyName("allowed_bandwidth")] public double? AllowedBandwidth { get; set; }
        }
    }

    private sealed class BandwidthResponse
    {
        /// <summary>键是 yyyy-MM-dd（UTC）</summary>
        [JsonPropertyName("bandwidth")]
        public Dictionary<string, Entry> Bandwidth { get; set; } = new();

        internal sealed class Entry
        {
            [JsonPropertyName("incoming_bytes")] public long IncomingBytes { get; set; }
            [JsonPropertyName("outgoing_bytes")] public long OutgoingBytes { get; set; }
        }
    }

    /// <summary>供设置界面"测试连接"使用的实例摘要。</summary>
    public sealed record InstanceSummary(
        string Id, string Label, string MainIp, string Region, double? AllowedBandwidthGB);

    public async Task<List<InstanceSummary>> ListInstancesAsync(CancellationToken ct = default)
    {
        var summaries = new List<InstanceSummary>();
        string? cursor = null;

        // 跟着 meta.links.next 翻页。以前只取第一页就返回，账号实例超过一页时
        // 后面那些会静默变成"配额未知"—— 没有任何报错，最难查的那种。
        // 加一个页数上限，免得上游游标出问题时在这里转不出去。
        for (var page = 0; page < 20; page++)
        {
            var path = "instances?per_page=500";
            if (!string.IsNullOrEmpty(cursor)) path += "&cursor=" + Uri.EscapeDataString(cursor);

            var response = await GetAsync<InstancesResponse>(path, ct).ConfigureAwait(false);
            summaries.AddRange(response.Instances.Select(i => new InstanceSummary(
                i.Id, i.Label ?? "", i.MainIp ?? "", i.Region ?? "", i.AllowedBandwidth)));

            cursor = response.Meta?.Links?.Next;
            if (string.IsNullOrEmpty(cursor)) break;
        }

        return summaries;
    }

    public async Task<CollectResult> FetchAsync(
        ServerConfig server, DateTime since, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(server.VultrInstanceId))
            throw CollectException.Misconfigured($"服务器「{server.Name}」未填写 Vultr 实例 ID");

        // 配额：只在用户没手填时才去问 API，省一次请求。
        //
        // 调度层若已经在本轮里拉过实例列表，会通过 _quotaLookup 把结果传进来 ——
        // 否则 N 台配额未填的 Vultr 实例就是 N 次全量列表请求，很容易撞上速率限制。
        double? reportedQuota = null;
        if (server.QuotaGB <= 0)
        {
            if (_quotaLookup is not null)
            {
                reportedQuota = _quotaLookup.TryGetValue(server.VultrInstanceId, out var cached)
                    ? cached : null;
            }
            else
            {
                var instances = await ListInstancesAsync(ct).ConfigureAwait(false);
                reportedQuota = instances
                    .FirstOrDefault(i => i.Id == server.VultrInstanceId)?.AllowedBandwidthGB;
            }
        }

        var bandwidth = await GetAsync<BandwidthResponse>(
            $"instances/{server.VultrInstanceId}/bandwidth", ct).ConfigureAwait(false);

        var sinceDay = UtcDay.String(since);
        var days = bandwidth.Bandwidth
            .Where(kv => string.CompareOrdinal(kv.Key, sinceDay) >= 0)
            .Select(kv => new DailyUsage(kv.Key, kv.Value.IncomingBytes, kv.Value.OutgoingBytes))
            .OrderBy(d => d.Day, StringComparer.Ordinal)
            .ToList();

        return new CollectResult { Days = days, ReportedQuotaGB = reportedQuota };
    }

    private async Task<T> GetAsync<T>(string path, CancellationToken ct)
    {
        if (string.IsNullOrEmpty(_apiKey))
            throw CollectException.Misconfigured("尚未设置 Vultr API Key");

        using var request = new HttpRequestMessage(HttpMethod.Get, $"{_baseUrl}/{path}");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _apiKey);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));

        using var response = await Http.SendAsync(request, ct).ConfigureAwait(false);
        var body = await response.Content.ReadAsStringAsync(ct).ConfigureAwait(false);

        if (!response.IsSuccessStatusCode)
        {
            var status = (int)response.StatusCode;
            // 401/403 十有八九是 API Key 写错，或者出口 IP 没加进 Vultr 的访问白名单。
            if (status is 401 or 403)
            {
                body += "\n提示：请确认 API Key 正确，且已在 Vultr 后台的 API 页面把你当前的出口 IP 加入允许访问的地址段。";
            }
            throw CollectException.Http(status, body);
        }

        try
        {
            return System.Text.Json.JsonSerializer.Deserialize<T>(body)
                   ?? throw CollectException.Decode("返回内容为空");
        }
        catch (System.Text.Json.JsonException ex)
        {
            throw CollectException.Decode(ex.Message);
        }
    }
}
