namespace VpsQuota.Collectors;

using System.IO;
using System.Linq;
using System.Net.Http;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using VpsQuota.Core;
using VpsQuota.Models;
using VpsQuota.Storage;

/// <summary>
/// 通过 RackNerd（SolusVM Client API）采集。与 macOS 端的 RackNerdCollector.swift 逐条对应。
/// </summary>
public sealed class RackNerdCollector : ICollector
{
    private static readonly HttpClient Http = CreateHttpClient();

    public const string DefaultEndpoint = "https://nerdvm.racknerd.com/api/client/command.php";

    private readonly string _apiKey;
    private readonly string _apiHash;
    private readonly string _endpoint;
    private readonly RackNerdStateStore _stateStore;

    public RackNerdCollector(
        string apiKey,
        string apiHash,
        string? endpoint = null,
        string? stateDirectory = null)
    {
        _apiKey = apiKey;
        _apiHash = apiHash;
        _endpoint = string.IsNullOrWhiteSpace(endpoint) ? DefaultEndpoint : endpoint.Trim();
        _stateStore = new RackNerdStateStore(stateDirectory ?? Path.Combine(AppPaths.Directory, "racknerd-state"));
    }

    /// <summary>裸 HttpClient 默认不发送 User-Agent，这种「无名」请求最容易被 WAF 优先拦截；API 客户端应带上身份。</summary>
    internal static HttpClient CreateHttpClient()
    {
        var client = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
        client.DefaultRequestHeaders.UserAgent.ParseAdd(
            $"VpsQuota/{AppInfo.Version} ({Environment.OSVersion.VersionString}; +{AppInfo.ProjectUrl})");
        return client;
    }

    internal sealed class SolusResponse
    {
        [JsonPropertyName("status")] public string? Status { get; set; }
        [JsonPropertyName("statusmsg")] public string? StatusMsg { get; set; }
        [JsonPropertyName("bw")] public string? Bw { get; set; }
    }

    public sealed record ServiceSummary(long TotalBytes, long UsedBytes, long FreeBytes, string Percent);

    public async Task<ServiceSummary> QueryInfoAsync(CancellationToken ct = default)
    {
        var (status, statusmsg, bwString) = await RequestRawAsync(ct).ConfigureAwait(false);

        if (!string.Equals(status, "success", StringComparison.OrdinalIgnoreCase))
        {
            var msg = string.IsNullOrWhiteSpace(statusmsg) ? "未知错误" : statusmsg;
            throw new CollectException($"RackNerd API 报错：{msg}。请核对 API Key 与 API Hash 是否正确。");
        }

        if (string.IsNullOrWhiteSpace(bwString))
        {
            throw new CollectException("RackNerd API 响应中未包含带宽数据（bw）。");
        }

        var parts = bwString.Split(',');
        if (parts.Length < 3)
        {
            throw CollectException.Decode($"RackNerd 带宽格式无效：{bwString}");
        }

        long.TryParse(parts[0].Trim(), out var total);
        long.TryParse(parts[1].Trim(), out var used);
        long.TryParse(parts[2].Trim(), out var free);
        var percent = parts.Length > 3 ? parts[3].Trim() : "";

        return new ServiceSummary(total, used, free, percent);
    }

    public async Task<CollectResult> FetchAsync(
        ServerConfig server, DateTime since, CancellationToken ct = default)
    {
        return await FetchAsync(server, since, DateTime.UtcNow, ct).ConfigureAwait(false);
    }

    internal async Task<CollectResult> FetchAsync(
        ServerConfig server, DateTime since, DateTime now, CancellationToken ct = default)
    {
        if (string.IsNullOrEmpty(_apiKey) || string.IsNullOrEmpty(_apiHash))
        {
            throw CollectException.Misconfigured($"尚未设置服务器「{server.Name}」的 RackNerd API Key 或 API Hash");
        }

        var summary = await QueryInfoAsync(ct).ConfigureAwait(false);
        var today = UtcDay.String(now);
        var previous = _stateStore.Load(server.Id);
        var (days, snapshot) = Derive(today, summary.UsedBytes, previous);

        try
        {
            _stateStore.Save(server.Id, snapshot);
        }
        catch (Exception ex)
        {
            throw new CollectException(
                $"无法保存 RackNerd 采集状态（{_stateStore.FilePath(server.Id)}）："
                + $"{ex.Message}。为避免流量被重复计算，本轮结果已丢弃");
        }

        return new CollectResult
        {
            Days = days,
            ReportedQuotaGB = summary.TotalBytes > 0 ? (double)summary.TotalBytes / 1_073_741_824d : null,
            Warnings = Array.Empty<string>(),
        };
    }

    public sealed class Snapshot
    {
        public string DayKey { get; set; } = "";
        public long DayStartCounter { get; set; }
        public long Counter { get; set; }
    }

    public static (IReadOnlyList<DailyUsage> Days, Snapshot Snapshot) Derive(
        string today, long counter, Snapshot? previous)
    {
        long baseCounter;
        if (previous is not null)
        {
            if (counter < previous.Counter)
            {
                baseCounter = 0;
            }
            else if (previous.DayKey == today)
            {
                baseCounter = previous.DayStartCounter;
            }
            else
            {
                baseCounter = previous.Counter;
            }
        }
        else
        {
            baseCounter = 0;
        }

        var dayBytes = Math.Max(0, counter - baseCounter);
        var snapshot = new Snapshot
        {
            DayKey = today,
            DayStartCounter = baseCounter,
            Counter = counter,
        };

        var days = new List<DailyUsage> { new(today, 0, dayBytes) };
        return (days, snapshot);
    }

    private async Task<(string Status, string StatusMsg, string? Bw)> RequestRawAsync(CancellationToken ct)
    {
        var uriBuilder = new UriBuilder(_endpoint);
        var query = $"key={Uri.EscapeDataString(_apiKey)}&hash={Uri.EscapeDataString(_apiHash)}&action=info&bw=true&rdtype=json";
        uriBuilder.Query = string.IsNullOrEmpty(uriBuilder.Query)
            ? query
            : uriBuilder.Query.TrimStart('?') + "&" + query;

        using var request = new HttpRequestMessage(HttpMethod.Get, uriBuilder.Uri);
        using var response = await Http.SendAsync(request, ct).ConfigureAwait(false);

        var body = await response.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode)
        {
            var cfMitigated = response.Headers.TryGetValues("cf-mitigated", out var values)
                ? values.FirstOrDefault()
                : null;
            throw BuildHttpError((int)response.StatusCode, cfMitigated, body);
        }

        try
        {
            var json = JsonSerializer.Deserialize<SolusResponse>(body);
            if (json is not null && !string.IsNullOrEmpty(json.Status))
            {
                return (json.Status ?? "", json.StatusMsg ?? "", json.Bw);
            }
        }
        catch
        {
            // 容错：转为 XML 正则解析
        }

        var status = ExtractXmlTag(body, "status") ?? "";
        var statusmsg = ExtractXmlTag(body, "statusmsg") ?? "";
        var bw = ExtractXmlTag(body, "bw");

        if (!string.IsNullOrEmpty(status) || bw is not null)
        {
            return (status, statusmsg, bw);
        }

        throw CollectException.Decode($"无法解析 RackNerd API 返回内容：{(body.Length > 200 ? body[..200] : body)}");
    }

    /// <summary>
    /// 2026-10 起 nerdvm.racknerd.com 整站开启 Cloudflare bot 质询（403 + "Just a moment..." 页面，
    /// 响应头 Cf-Mitigated: challenge），原生 HTTP 客户端无法通过。若把质询页 HTML 原样透出，
    /// 用户会误以为是自己密钥配错，这里识别出来并写明原因与出路。
    /// </summary>
    internal static CollectException BuildHttpError(int status, string? cfMitigated, string body)
    {
        var challenged = (status == 403 || status == 503)
            && (string.Equals(cfMitigated, "challenge", StringComparison.OrdinalIgnoreCase)
                || body.Contains("Just a moment", StringComparison.Ordinal)
                || body.Contains("Checking your browser", StringComparison.Ordinal));
        if (challenged)
        {
            return new CollectException(
                "RackNerd 端点被 Cloudflare 人机验证拦截（HTTP " + status + "）。"
                + "这是 RackNerd 服务端的防护，API Key 与 API Hash 并没有问题："
                + "可尝试把端点 URL 换成 VPS 开通邮件中的控制面板地址；"
                + "仍失败时请向 RackNerd 提工单，要求对 API 放行。");
        }
        return CollectException.Http(status, body);
    }

    private static string? ExtractXmlTag(string text, string tag)
    {
        var match = Regex.Match(text, $@"<{tag}>(.*?)</{tag}>", RegexOptions.Singleline);
        return match.Success ? match.Groups[1].Value.Trim() : null;
    }
}

public sealed class RackNerdStateStore
{
    private readonly string _directory;

    public RackNerdStateStore(string directory) => _directory = directory;

    public RackNerdCollector.Snapshot? Load(string serverId)
    {
        var path = FilePath(serverId);
        if (!File.Exists(path)) return null;

        try
        {
            var json = File.ReadAllText(path);
            return JsonSerializer.Deserialize<RackNerdCollector.Snapshot>(json);
        }
        catch
        {
            return null;
        }
    }

    public void Save(string serverId, RackNerdCollector.Snapshot snapshot)
    {
        Directory.CreateDirectory(_directory);
        var path = FilePath(serverId);
        var temp = path + ".tmp";
        var json = JsonSerializer.Serialize(snapshot, new JsonSerializerOptions { WriteIndented = true });
        File.WriteAllText(temp, json);
        File.Move(temp, path, overwrite: true);
    }

    public string FilePath(string serverId)
    {
        var safe = string.Concat(serverId.Select(c => char.IsLetterOrDigit(c) ? c : '-'));
        return Path.Combine(_directory, $"{safe}.json");
    }
}
