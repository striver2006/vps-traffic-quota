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
    private readonly Dictionary<string, string> _lastErrors = new();
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

        await Task.WhenAll(servers.Select(s => RefreshOneAsync(s, now, ct))).ConfigureAwait(false);
        await _store.PruneFetchLogAsync(90, now).ConfigureAwait(false);

        return await StatusesAsync(now).ConfigureAwait(false);
    }

    /// <summary>只刷新一台，供设置界面的"测试连接"使用。返回 null 表示成功。</summary>
    public async Task<string?> RefreshOneAsync(
        ServerConfig server, DateTime now, CancellationToken ct = default)
    {
        var period = BillingPeriod.Current(server.ResetDay, now);

        try
        {
            var collector = MakeCollector(server);
            var result = await collector.FetchAsync(server, period.Start, ct).ConfigureAwait(false);

            await _store.UpsertAsync(server.Id, result.Days).ConfigureAwait(false);
            await _store.LogFetchAsync(server.Id, now, ok: true, error: null).ConfigureAwait(false);

            await _stateGate.WaitAsync(ct).ConfigureAwait(false);
            try
            {
                if (result.ReportedQuotaGB is { } quota) _reportedQuota[server.Id] = quota;
                _lastErrors.Remove(server.Id);
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

        foreach (var server in _config.Servers)
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
            try
            {
                quota = _reportedQuota.TryGetValue(server.Id, out var q) ? q : null;
                error = _lastErrors.GetValueOrDefault(server.Id);
                warnings = _lastWarnings.GetValueOrDefault(server.Id);
            }
            finally { _stateGate.Release(); }

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

    private ICollector MakeCollector(ServerConfig server) => server.Provider switch
    {
        ProviderKind.Vultr => string.IsNullOrEmpty(_vultrApiKey)
            ? throw CollectException.Misconfigured("尚未设置 Vultr API Key，请在设置中填写")
            : new VultrCollector(_vultrApiKey),
        ProviderKind.Ssh => new SshVnstatCollector(),
        _ => throw CollectException.Misconfigured($"未知的服务商类型：{server.Provider}"),
    };
}
