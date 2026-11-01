namespace VpsQuota.Collectors;

using System.IO;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text.Json;
using System.Text.Json.Serialization;
using VpsQuota.Core;
using VpsQuota.Models;
using VpsQuota.Storage;

/// <summary>
/// 通过 Hetzner Cloud 官方 REST API 采集。与 macOS 端的 HetznerCollector.swift 逐条对应。
/// </summary>
public sealed class HetznerCollector : ICollector
{
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(30) };

    private readonly string _apiToken;
    private readonly string _baseUrl;
    private readonly HetznerStateStore _stateStore;

    public HetznerCollector(
        string apiToken,
        string baseUrl = "https://api.hetzner.cloud/v1",
        string? stateDirectory = null)
    {
        _apiToken = apiToken;
        _baseUrl = baseUrl.TrimEnd('/');
        _stateStore = new HetznerStateStore(stateDirectory ?? Path.Combine(AppPaths.Directory, "hetzner-state"));
    }

    public sealed class ServerInfo
    {
        [JsonPropertyName("id")] public long Id { get; set; }
        [JsonPropertyName("name")] public string Name { get; set; } = "";
        [JsonPropertyName("status")] public string Status { get; set; } = "";
        [JsonPropertyName("outgoing_traffic")] public long? OutgoingTraffic { get; set; }
        [JsonPropertyName("ingoing_traffic")] public long? IngoingTraffic { get; set; }
        [JsonPropertyName("included_traffic")] public long? IncludedTraffic { get; set; }
    }

    internal sealed class ServerWrapper
    {
        [JsonPropertyName("server")] public ServerInfo? Server { get; set; }
    }

    internal sealed class ServerListWrapper
    {
        [JsonPropertyName("servers")] public List<ServerInfo>? Servers { get; set; }
    }

    public async Task<List<ServerInfo>> ListServersAsync(CancellationToken ct = default)
    {
        var wrapper = await RequestAsync<ServerListWrapper>("servers", ct).ConfigureAwait(false);
        return wrapper.Servers ?? new List<ServerInfo>();
    }

    public async Task<ServerInfo> ServerInfoAsync(string id, CancellationToken ct = default)
    {
        var wrapper = await RequestAsync<ServerWrapper>($"servers/{id}", ct).ConfigureAwait(false);
        return wrapper.Server ?? throw CollectException.Decode($"Hetzner 服务器响应中缺少 server 节点");
    }

    public async Task<CollectResult> FetchAsync(
        ServerConfig server, DateTime since, CancellationToken ct = default)
    {
        return await FetchAsync(server, since, DateTime.UtcNow, ct).ConfigureAwait(false);
    }

    internal async Task<CollectResult> FetchAsync(
        ServerConfig server, DateTime since, DateTime now, CancellationToken ct = default)
    {
        var serverId = server.HetznerServerId?.Trim();
        if (string.IsNullOrEmpty(serverId))
        {
            throw CollectException.Misconfigured($"服务器「{server.Name}」未填写 Hetzner Server ID");
        }
        if (string.IsNullOrEmpty(_apiToken))
        {
            throw CollectException.Misconfigured("尚未设置 Hetzner API Token，请在设置中填写");
        }

        var info = await ServerInfoAsync(serverId, ct).ConfigureAwait(false);

        var warnings = new List<string>();
        if (!string.Equals(info.Status, "running", StringComparison.OrdinalIgnoreCase))
        {
            warnings.Add($"Hetzner 报告该服务器状态为 {info.Status}");
        }

        var currentPeriod = BillingPeriod.Current(server.ResetDay, now);
        var today = UtcDay.String(now);
        var tx = info.OutgoingTraffic ?? 0;
        var rx = info.IngoingTraffic ?? 0;

        var previous = _stateStore.Load(server.Id);
        var (days, snapshot) = Derive(today, currentPeriod.StartDay, tx, rx, previous);

        try
        {
            _stateStore.Save(server.Id, snapshot);
        }
        catch (Exception ex)
        {
            throw new CollectException(
                $"无法保存 Hetzner 采集状态（{_stateStore.FilePath(server.Id)}）："
                + $"{ex.Message}。为避免流量被重复计算，本轮结果已丢弃");
        }

        var includedBytes = info.IncludedTraffic ?? 0;
        return new CollectResult
        {
            Days = days,
            ReportedQuotaGB = includedBytes > 0 ? (double)includedBytes / 1_073_741_824d : null,
            Warnings = warnings,
        };
    }

    public sealed class Snapshot
    {
        public string DayKey { get; set; } = "";
        public long DayStartTx { get; set; }
        public long DayStartRx { get; set; }
        public long TxCounter { get; set; }
        public long RxCounter { get; set; }
        public string PeriodStart { get; set; } = "";
    }

    public static (IReadOnlyList<DailyUsage> Days, Snapshot Snapshot) Derive(
        string today, string periodStart, long txCounter, long rxCounter, Snapshot? previous)
    {
        long baseTx;
        long baseRx;

        if (previous is not null)
        {
            if (periodStart != previous.PeriodStart || txCounter < previous.TxCounter)
            {
                baseTx = 0;
                baseRx = 0;
            }
            else if (previous.DayKey == today)
            {
                baseTx = previous.DayStartTx;
                baseRx = previous.DayStartRx;
            }
            else
            {
                baseTx = previous.TxCounter;
                baseRx = previous.RxCounter;
            }
        }
        else
        {
            baseTx = 0;
            baseRx = 0;
        }

        var dayTx = Math.Max(0, txCounter - baseTx);
        var dayRx = Math.Max(0, rxCounter - baseRx);

        var snapshot = new Snapshot
        {
            DayKey = today,
            DayStartTx = baseTx,
            DayStartRx = baseRx,
            TxCounter = txCounter,
            RxCounter = rxCounter,
            PeriodStart = periodStart,
        };

        var days = new List<DailyUsage> { new(today, rxBytes: dayRx, txBytes: dayTx) };
        return (days, snapshot);
    }

    private async Task<T> RequestAsync<T>(string path, CancellationToken ct)
    {
        if (string.IsNullOrEmpty(_apiToken))
        {
            throw CollectException.Misconfigured("尚未设置 Hetzner API Token");
        }

        var url = $"{_baseUrl}/{path.TrimStart('/')}";
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _apiToken);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));

        using var response = await Http.SendAsync(request, ct).ConfigureAwait(false);
        var body = await response.Content.ReadAsStringAsync(ct).ConfigureAwait(false);

        if (!response.IsSuccessStatusCode)
        {
            if (response.StatusCode == System.Net.HttpStatusCode.Unauthorized)
            {
                throw new CollectException("Hetzner API Token 无效或已过期");
            }
            if (response.StatusCode == System.Net.HttpStatusCode.Forbidden)
            {
                throw new CollectException("Hetzner API Token 权限不足，请确认具有读取权限");
            }
            if (response.StatusCode == System.Net.HttpStatusCode.NotFound)
            {
                throw new CollectException($"Hetzner 未找到指定资源（{path}）");
            }
            throw CollectException.Http((int)response.StatusCode, body);
        }

        try
        {
            return JsonSerializer.Deserialize<T>(body)
                ?? throw CollectException.Decode($"Hetzner 响应为空");
        }
        catch (JsonException ex)
        {
            throw CollectException.Decode(ex.Message);
        }
    }
}

public sealed class HetznerStateStore
{
    private readonly string _directory;

    public HetznerStateStore(string directory) => _directory = directory;

    public HetznerCollector.Snapshot? Load(string serverId)
    {
        var path = FilePath(serverId);
        if (!File.Exists(path)) return null;

        try
        {
            var json = File.ReadAllText(path);
            return JsonSerializer.Deserialize<HetznerCollector.Snapshot>(json);
        }
        catch
        {
            return null;
        }
    }

    public void Save(string serverId, HetznerCollector.Snapshot snapshot)
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
