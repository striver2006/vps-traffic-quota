namespace VpsQuota.Scheduler;

using VpsQuota.Collectors;
using VpsQuota.Core;
using VpsQuota.Models;
using VpsQuota.Storage;

/// <summary>
/// 采集调度与状态汇总。
///
/// 与 macOS 端的 TrafficMonitor 一一对应：负责并发采集、落库、
/// 以及把本地数据折算成 <see cref="ServerStatus"/>。
/// </summary>
public sealed class TrafficMonitor
{
    private readonly SqliteStore _store;
    private readonly SemaphoreSlim _stateGate = new(1, 1);

    private AppConfig _config;
    private string? _vultrApiKey;

    /// <summary>
    /// Vultr 报告的配额缓存。只在用户没手填配额时才有意义，
    /// 缓存它是为了让"离线读本地数据"这条路径也能显示出配额。
    /// </summary>
    private readonly Dictionary<string, double> _reportedQuota = new();
    /// <summary>
    /// 本轮各台的错误。值可为 null —— 需要区分「这一轮还没采过」（键不存在，回落读库）
    /// 与「这一轮采成功了，没有错误」（键存在、值为 null，不该再把库里的旧错误捞回来）。
    /// </summary>
    private readonly Dictionary<string, string?> _lastErrors = new();
    private readonly Dictionary<string, IReadOnlyList<string>> _lastWarnings = new();

    public TrafficMonitor(SqliteStore store, AppConfig config, string? vultrApiKey)
    {
        _store = store;
        _config = config;
        _vultrApiKey = vultrApiKey;
    }

    public AppConfig Config => _config;

    public void UpdateConfig(AppConfig config) => _config = config;

    public void SetVultrApiKey(string? key) => _vultrApiKey = key;

    /// <summary>
    /// 并发采集所有服务器，落库后返回最新状态。
    ///
    /// 单台失败不影响其他台：错误被记入 fetch_log 并挂在该台的 LastError 上，
    /// 界面依然显示它上次成功采集到的数据。这一点很重要 ——
    /// 一台机器 SSH 不通不应该让整个面板变成空白。
    /// </summary>
    public async Task<List<ServerStatus>> RefreshAllAsync(CancellationToken ct = default)
    {
        var now = DateTime.UtcNow;
        var servers = _config.Servers.ToList();

        // 本轮所有配额未手填的 Vultr 实例共用一次实例列表请求。
        // 每台各拉一次的话，返回的其实是同一份数据，白白逼近上游的速率限制。
        var quotaLookup = await FetchVultrQuotasAsync(servers, ct).ConfigureAwait(false);

        await Task.WhenAll(servers.Select(s => RefreshOneAsync(s, now, ct, quotaLookup)))
            .ConfigureAwait(false);
        await _store.PruneFetchLogAsync(90, now).ConfigureAwait(false);

        return await StatusesAsync(now).ConfigureAwait(false);
    }

    /// <summary>只刷新一台，供设置界面的"测试连接"使用。返回 null 表示成功。</summary>
    public async Task<string?> RefreshOneAsync(
        ServerConfig server, DateTime now, CancellationToken ct = default,
        IReadOnlyDictionary<string, double>? quotaLookup = null)
    {
        var period = BillingPeriod.Current(server.ResetDay, now);

        try
        {
            var collector = MakeCollector(server, quotaLookup);
            var result = await collector.FetchAsync(server, period.Start, ct).ConfigureAwait(false);

            await _store.UpsertAsync(server.Id, result.Days).ConfigureAwait(false);
            await _store.LogFetchAsync(server.Id, now, ok: true, error: null).ConfigureAwait(false);

            // 也落盘：否则重启后到首次采集成功之间，QuotaGB 填 0 的 Vultr 实例
            // 会显示成"配额未知"，进度条消失（S3）。
            await _store.SetReportedQuotaAsync(server.Id, result.ReportedQuotaGB).ConfigureAwait(false);

            await _stateGate.WaitAsync(ct).ConfigureAwait(false);
            try
            {
                if (result.ReportedQuotaGB is { } quota) _reportedQuota[server.Id] = quota;
                // 置 null 而不是 Remove：StatusesAsync 用「字典里没有这个键」作为
                // 回落读库的信号，Remove 的话刚采集成功的这台又会把库里那条旧错误捞回来。
                _lastErrors[server.Id] = null;
                _lastWarnings[server.Id] = result.Warnings;
            }
            finally { _stateGate.Release(); }

            return null;
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            var message = ex.Message;

            await _stateGate.WaitAsync(CancellationToken.None).ConfigureAwait(false);
            try { _lastErrors[server.Id] = message; }
            finally { _stateGate.Release(); }

            try
            {
                await _store.LogFetchAsync(server.Id, now, ok: false, error: message).ConfigureAwait(false);
            }
            catch
            {
                // 连日志都写不进去时不要再抛，否则会盖掉真正的采集错误。
            }
            return message;
        }
    }

    /// <summary>
    /// 只读本地数据库计算状态，不发起任何网络请求。
    ///
    /// 应用启动时先走这条，界面立刻有内容，再在后台发起真正的刷新。
    /// </summary>
    public async Task<List<ServerStatus>> StatusesAsync(DateTime? at = null)
    {
        var now = at ?? DateTime.UtcNow;
        var result = new List<ServerStatus>();

        // 必须先快照：循环体里有 await（读库），而设置窗口会在 UI 线程上直接增删
        // _config.Servers —— 一轮 SSH 采集要十几秒，用户完全来得及在这期间改配置，
        // 直接 foreach 会抛 InvalidOperationException。RefreshAllAsync 已经这么做了。
        var servers = _config.Servers.ToList();

        foreach (var server in servers)
        {
            var period = BillingPeriod.Current(server.ResetDay, now);
            var days = await _store
                .DaysAsync(server.Id, period.StartDay, period.EndDayExclusive)
                .ConfigureAwait(false);
            var lastSuccess = await _store.LastSuccessAsync(server.Id).ConfigureAwait(false);

            await _stateGate.WaitAsync().ConfigureAwait(false);
            double? quota;
            string? error;
            IReadOnlyList<string>? warnings;
            bool hasQuota, hasError;
            try
            {
                hasQuota = _reportedQuota.TryGetValue(server.Id, out var q);
                quota = hasQuota ? q : null;
                hasError = _lastErrors.TryGetValue(server.Id, out error);
                warnings = _lastWarnings.GetValueOrDefault(server.Id);
            }
            finally { _stateGate.Release(); }

            // 本轮内存里没有的，回落读库 —— 这样应用刚启动、一次都还没采集时，
            // 界面显示的也是上次退出前的真实状况，而不是"配额未知 + 一切正常"这种假象。
            if (!hasQuota) quota = await _store.ReportedQuotaAsync(server.Id).ConfigureAwait(false);
            if (!hasError) error = await _store.LastErrorAsync(server.Id).ConfigureAwait(false);

            result.Add(QuotaCalculator.Status(
                server, days, now, quota, lastSuccess, error, warnings));
        }

        return result;
    }

    /// <summary>取某台服务器指定天数内的历史，用于趋势图（可跨账期）。</summary>
    public async Task<List<DailyUsage>> HistoryAsync(string serverId, int days)
    {
        var now = DateTime.UtcNow;
        var from = UtcDay.String(now.AddDays(-days));
        var to = UtcDay.String(now.AddDays(1));
        return await _store.DaysAsync(serverId, from, to).ConfigureAwait(false);
    }

    /// <summary>
    /// 一轮刷新开始时把 Vultr 的实例列表拉一次，供本轮所有 Vultr 采集共用。
    /// </summary>
    /// <remarks>
    /// 没有配额未填的 Vultr 实例时不发请求；拉取失败也不算错误 ——
    /// 各台照常走自己的采集路径，只是退回到"自己去问"而已。
    /// </remarks>
    private async Task<IReadOnlyDictionary<string, double>?> FetchVultrQuotasAsync(
        List<ServerConfig> servers, CancellationToken ct)
    {
        var needsQuota = servers.Any(s => s.Provider == ProviderKind.Vultr && s.QuotaGB <= 0);
        if (!needsQuota || string.IsNullOrEmpty(_vultrApiKey)) return null;

        try
        {
            var instances = await new VultrCollector(_vultrApiKey)
                .ListInstancesAsync(ct).ConfigureAwait(false);

            var table = new Dictionary<string, double>();
            foreach (var instance in instances)
            {
                if (instance.AllowedBandwidthGB is { } quota) table[instance.Id] = quota;
            }
            return table;
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            return null;
        }
    }

    private ICollector MakeCollector(
        ServerConfig server,
        IReadOnlyDictionary<string, double>? quotaLookup = null) => server.Provider switch
    {
        ProviderKind.Vultr => string.IsNullOrEmpty(_vultrApiKey)
            ? throw CollectException.Misconfigured("尚未设置 Vultr API Key，请在设置中填写")
            : new VultrCollector(_vultrApiKey, quotaLookup: quotaLookup),
        ProviderKind.Ssh => new SshVnstatCollector(),
        _ => throw CollectException.Misconfigured($"未知的服务商类型：{server.Provider}"),
    };
}
