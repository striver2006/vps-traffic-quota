namespace VpsQuota.Collectors;

using System.IO;
using System.Net.Http;
using System.Text.Json;
using System.Text.Json.Serialization;
using VpsQuota.Core;
using VpsQuota.Models;
using VpsQuota.Storage;

/// <summary>
/// 通过搬瓦工（BandwagonHost）KiwiVM API 采集。与 macOS 端的 BwgCollector.swift 逐条对应。
///
/// KiwiVM 只暴露一个<b>账期累计计数器</b>：getServiceInfo 的 data_counter 是本计费
/// 周期开始以来的计费字节总量，没有按天的历史序列（getRawUsageStats 的明细是
/// Detailed Statistics 的原始采样，不含计费系数，窗口也短，撑不起一个账期）。
/// 所以这里用「计数器差值」把累计值还原成按天用量：
///
/// <list type="bullet">
/// <item>本地状态文件（bwg-state\&lt;veid&gt;.json，与应用数据库同目录）记一份快照：
///   DayKey（快照所属 UTC 日）、DayStartCounter（当日基线）、Counter（最近观测值）、
///   NextReset（重置时间戳，用于识别换账期）。</item>
/// <item>当天用量 = 当前计数器 − 当日基线，<b>每次都绝对重算</b>。于是覆盖式 upsert 天然幂等，
///   某一轮落库失败也不会让数字错位 —— 下一轮重算的还是同一个绝对值。</item>
/// <item>跨天时取「昨天最后一次观测值」当今天的基线；应用停采期间的增量会整段记到
///   恢复采集的那一天（总量仍然正确，只是那天的柱子偏高）。</item>
/// <item>换账期（计数器回落，或 data_next_reset 变化）时基线归零。</item>
/// <item>首次接入没有快照：基线取 0，<b>整个已用计数器都记到当天</b>。账期总量因此立即与
///   面板一致，代价是趋势图首日有一根大柱子。此时不要再填「起始已用量」，
///   否则同一个缺口被补两遍。</item>
/// </list>
///
/// 计数器与配额按官方要求都要乘 monthly_data_multiplier（部分机房带宽更贵，
/// 系数小于 1），折算在这一层完成，往下各层拿到的是已按计费口径的字节数 ——
/// 与 KiwiVM 面板显示的数字同口径。计数器是单一计费值（进出已合算），
/// 记在 tx 一栏、rx 恒为 0，服务器的计费口径应保持「仅出站」。
///
/// 鉴权走查询参数 veid + api_key（KiwiVM 的固定方案），每个 VEID 有自己的 Key，
/// 与 Vultr 的账号级 Key 不同。官方有速率限制（15 分钟 / 24 小时两档积分），
/// 刷新周期不必低于 60 分钟。
/// </summary>
public sealed class BwgCollector : ICollector
{
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(30) };

    private readonly string _apiKey;
    private readonly string _baseUrl;
    private readonly BwgStateStore _stateStore;

    public BwgCollector(
        string apiKey,
        string baseUrl = "https://api.64clouds.com/v1",
        string? stateDirectory = null)
    {
        _apiKey = apiKey;
        _baseUrl = baseUrl.TrimEnd('/');
        _stateStore = new BwgStateStore(stateDirectory ?? Path.Combine(AppPaths.Directory, "bwg-state"));
    }

    // 响应模型

    internal sealed class ServiceInfoResponse
    {
        [JsonPropertyName("error")] public int? Error { get; set; }
        [JsonPropertyName("message")] public string? Message { get; set; }
        [JsonPropertyName("plan")] public string? Plan { get; set; }
        [JsonPropertyName("node_location")] public string? NodeLocation { get; set; }
        [JsonPropertyName("plan_monthly_data")] public long? PlanMonthlyData { get; set; }
        [JsonPropertyName("data_counter")] public long? DataCounter { get; set; }
        [JsonPropertyName("monthly_data_multiplier")] public double? MonthlyDataMultiplier { get; set; }
        [JsonPropertyName("data_next_reset")] public long? DataNextReset { get; set; }

        [JsonPropertyName("suspended"), JsonConverter(typeof(FlexibleBoolConverter))]
        public bool? Suspended { get; set; }
    }

    /// <summary>KiwiVM 的布尔字段新旧版本一会儿给 true/false、一会儿给 0/1，两种都收。</summary>
    private sealed class FlexibleBoolConverter : JsonConverter<bool?>
    {
        public override bool? Read(
            ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
            reader.TokenType switch
            {
                JsonTokenType.True => true,
                JsonTokenType.False => false,
                JsonTokenType.Number => reader.TryGetInt64(out var v) && v != 0,
                JsonTokenType.Null => null,
                _ => throw new JsonException("suspended 字段既不是布尔也不是数值"),
            };

        public override void Write(Utf8JsonWriter writer, bool? value, JsonSerializerOptions options) =>
            writer.WriteBooleanValue(value ?? false);
    }

    /// <summary>服务概况。字节数均已乘 monthly_data_multiplier。</summary>
    public sealed record ServiceSummary(
        string? Plan, string? NodeLocation, long UsedBytes, long QuotaBytes,
        DateTime? NextReset, bool Suspended);

    /// <summary>拉一次 getServiceInfo 并折成概况。</summary>
    public async Task<ServiceSummary> GetServiceInfoAsync(string veid, CancellationToken ct = default)
    {
        var info = await GetAsync<ServiceInfoResponse>("getServiceInfo", veid, ct).ConfigureAwait(false);
        ThrowIfApiError(info);

        var multiplier = info.MonthlyDataMultiplier ?? 1;
        return new ServiceSummary(
            info.Plan, info.NodeLocation,
            BilledBytes(info.DataCounter ?? 0, multiplier),
            BilledBytes(info.PlanMonthlyData ?? 0, multiplier),
            info.DataNextReset is > 0
                ? DateTimeOffset.FromUnixTimeSeconds(info.DataNextReset.Value).UtcDateTime
                : null,
            info.Suspended == true);
    }

    // ICollector

    public async Task<CollectResult> FetchAsync(
        ServerConfig server, DateTime since, CancellationToken ct = default)
        => await FetchAsync(server, since, DateTime.UtcNow, ct).ConfigureAwait(false);

    /// <summary>now 单独传入纯粹是为了可测，接口方法固定用当前时间。</summary>
    internal async Task<CollectResult> FetchAsync(
        ServerConfig server, DateTime since, DateTime now, CancellationToken ct = default)
    {
        var veid = server.BwgVeid?.Trim();
        if (string.IsNullOrEmpty(veid))
            throw CollectException.Misconfigured($"服务器「{server.Name}」未填写搬瓦工 VEID");
        if (string.IsNullOrEmpty(_apiKey))
            throw CollectException.Misconfigured("尚未设置这台服务器的 KiwiVM API Key");

        var info = await GetAsync<ServiceInfoResponse>("getServiceInfo", veid, ct).ConfigureAwait(false);
        ThrowIfApiError(info);

        var multiplier = info.MonthlyDataMultiplier ?? 1;
        var counter = BilledBytes(info.DataCounter ?? 0, multiplier);
        var nextReset = info.DataNextReset ?? 0;

        var warnings = new List<string>();
        if (info.Suspended == true)
            warnings.Add("KiwiVM 报告该 VPS 当前处于暂停（suspended）状态");
        if (ResetDayMismatch(server.ResetDay, nextReset) is { } mismatch)
        {
            warnings.Add(
                $"KiwiVM 面板的流量重置日是每月 {mismatch.Actual} 号，与配置的重置日 {server.ResetDay} 号" +
                $"推算的不一致，账期切分会有偏差。请对照 KiwiVM 面板的「下次重置」修正「每月重置日」");
        }

        var today = UtcDay.String(now);
        var (days, snapshot) = Derive(today, counter, nextReset, _stateStore.Load(veid));

        // 状态必须先于返回值落盘：快照推进不了，这次的结果就不能用 ——
        // 否则下一轮会把同一段流量再记一遍。落盘失败时宁可这轮采集失败。
        try
        {
            _stateStore.Save(veid, snapshot);
        }
        catch (Exception ex)
        {
            throw CollectException.NoData(
                $"无法保存搬瓦工采集状态（{_stateStore.FilePath(veid)}）：{ex.Message}。" +
                "为避免流量被重复计算，本轮结果已丢弃");
        }

        var quotaBytes = BilledBytes(info.PlanMonthlyData ?? 0, multiplier);
        return new CollectResult
        {
            Days = days,
            ReportedQuotaGB = quotaBytes > 0 ? quotaBytes / 1_073_741_824d : null,
            Warnings = warnings,
        };
    }

    // 差值算法（纯函数，可单测）

    public sealed record Snapshot(
        string DayKey, long DayStartCounter, long Counter, long NextReset);

    /// <summary>
    /// 由「上次快照 + 本次观测」推出今天应记录的用量与新快照。
    ///
    /// 基线的取法（按优先级）：
    /// 1. 换账期（计数器回落或 NextReset 变化）→ 0，整个新计数器都是本账期的；
    /// 2. 还是同一天 → 上次的当日基线，用量随观测绝对增长（幂等）；
    /// 3. 跨到新的一天 → 上次观测值当作今天的起点（停采期间的增量落在新一天）。
    /// </summary>
    internal static (List<DailyUsage> Days, Snapshot Snapshot) Derive(
        string today, long counter, long nextReset, Snapshot? previous)
    {
        long baseValue;
        if (previous is { } prev)
        {
            if (counter < prev.Counter || nextReset != prev.NextReset) baseValue = 0;
            else if (prev.DayKey == today) baseValue = prev.DayStartCounter;
            else baseValue = prev.Counter;
        }
        else
        {
            baseValue = 0;
        }

        var dayBytes = Math.Max(0, counter - baseValue);
        return (
            new List<DailyUsage> { new(today, 0, dayBytes) },
            new Snapshot(today, baseValue, counter, nextReset));
    }

    /// <summary>官方口径：data_counter / plan_monthly_data 都要乘 monthly_data_multiplier。</summary>
    internal static long BilledBytes(long raw, double multiplier) =>
        (long)Math.Round(raw * multiplier, MidpointRounding.AwayFromZero);

    internal static void ThrowIfApiError(ServiceInfoResponse info)
    {
        if (info.Error is { } code and not 0)
        {
            var detail = string.IsNullOrEmpty(info.Message) ? "未知错误" : info.Message;
            throw CollectException.NoData(
                $"KiwiVM API 报错（error {code}）：{detail}。请核对 VEID 与 API Key 是否匹配。");
        }
    }

    /// <summary>
    /// 校验配置的重置日与面板报告的是否一致。
    /// 返回 null 表示一致（或上游没给 data_next_reset，无从校验）；
    /// 否则返回实际日号与配置日（按月末钳制后）的期望值，供警告文案使用。
    /// 「月末钳制」语义与 BillingPeriod 相同：31 号遇上 2 月按 28/29 号算。
    /// </summary>
    internal static (int Actual, int Expected)? ResetDayMismatch(int configured, long nextReset)
    {
        if (nextReset <= 0) return null;

        var date = DateTimeOffset.FromUnixTimeSeconds(nextReset).UtcDateTime;
        var actual = date.Day;
        var expected = Math.Clamp(configured, 1, DateTime.DaysInMonth(date.Year, date.Month));
        return actual == expected ? null : (actual, expected);
    }

    // HTTP

    private async Task<T> GetAsync<T>(string path, string veid, CancellationToken ct)
    {
        if (string.IsNullOrEmpty(_apiKey))
            throw CollectException.Misconfigured("尚未设置这台服务器的 KiwiVM API Key");

        var url = $"{_baseUrl}/{path}?veid={Uri.EscapeDataString(veid)}&api_key={Uri.EscapeDataString(_apiKey)}";
        using var response = await Http.GetAsync(url, ct).ConfigureAwait(false);
        var body = await response.Content.ReadAsStringAsync(ct).ConfigureAwait(false);

        if (!response.IsSuccessStatusCode)
            throw CollectException.Http((int)response.StatusCode, body);

        try
        {
            return JsonSerializer.Deserialize<T>(body)
                   ?? throw CollectException.Decode("返回内容为空");
        }
        catch (JsonException ex)
        {
            throw CollectException.Decode(ex.Message);
        }
    }
}

/// <summary>
/// 每个 VEID 一份的采集快照，落在应用数据目录的 bwg-state\ 下。
/// 一台一个文件而不是全挤一个 JSON：并发采集不同 VEID 时互不干扰，不需要加锁。
/// 读写失败由调用方决定是否算采集失败。
/// </summary>
public sealed class BwgStateStore
{
    private readonly string _directory;

    public BwgStateStore(string directory) => _directory = directory;

    private static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true,
        // 与 macOS 端 BwgStateStore 的键名逐字对应：dayKey / dayStartCounter / counter / nextReset。
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    };

    /// <summary>读不到（不存在 / 解析失败）一律返回 null —— 调用方按「首次观测」处理。</summary>
    public BwgCollector.Snapshot? Load(string veid)
    {
        try
        {
            var path = FilePath(veid);
            if (!File.Exists(path)) return null;
            return JsonSerializer.Deserialize<BwgCollector.Snapshot>(File.ReadAllText(path), Options);
        }
        catch (Exception ex) when (ex is IOException or JsonException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    public void Save(string veid, BwgCollector.Snapshot snapshot)
    {
        Directory.CreateDirectory(_directory);

        var path = FilePath(veid);
        var temp = path + ".tmp";
        File.WriteAllText(temp, JsonSerializer.Serialize(snapshot, Options));
        File.Move(temp, path, overwrite: true);
    }

    public string FilePath(string veid)
    {
        // VEID 理论上是纯数字；万一混进别的字符也别让它跑出目录。
        var safe = new string(veid.Select(c => char.IsLetterOrDigit(c) ? c : '-').ToArray());
        return Path.Combine(_directory, safe + ".json");
    }
}
