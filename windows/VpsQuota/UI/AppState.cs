namespace VpsQuota.UI;

using System.Threading;
using System.Windows;
using System.Windows.Threading;
using VpsQuota.Models;
using VpsQuota.Scheduler;
using VpsQuota.Storage;

/// <summary>
/// 界面的唯一状态源，对应 macOS 端的 AppModel。
///
/// 负责：把 <see cref="TrafficMonitor"/> 的异步接口收敛到 UI 线程、
/// 管理自动刷新定时器、以及配置与凭据的读写。
/// </summary>
public sealed class AppState
{
    private readonly ConfigStore _configStore = new();
    private readonly SqliteStore? _store;
    private readonly TrafficMonitor? _monitor;
    private readonly DispatcherTimer _timer = new();

    /// <summary>应用生命周期。退出时取消它，让在途的 ssh 进程立刻收摊而不是干等 45 秒超时。</summary>
    private readonly CancellationTokenSource _lifetime = new();

    private SettingsWindow? _settingsWindow;
    private MainWindow? _mainWindow;

    public AppConfig Config { get; private set; }

    /// <summary>仅用于设置界面回填，不写进配置文件。</summary>
    public string VultrApiKey { get; set; } = "";

    public IReadOnlyList<ServerStatus> Statuses { get; private set; } = Array.Empty<ServerStatus>();
    public bool IsRefreshing { get; private set; }
    public DateTime? LastRefreshAt { get; private set; }

    /// <summary>启动阶段的致命错误（例如数据库打不开），非 null 时界面只显示它。</summary>
    public string? FatalError { get; private set; }

    /// <summary>
    /// 最近一次整体性刷新故障（库写不进去、磁盘满等）。与 <see cref="FatalError"/> 分开，
    /// 是因为它会随下一次成功刷新自动消失，而启动期的故障不该被这样冲掉。
    /// 单台采集的失败不会走到这里 —— 那些已经在 TrafficMonitor 里被隔离到各自的 LastError 上。
    /// </summary>
    public string? RefreshError { get; private set; }

    public event Action? StatusesChanged;

    public AppState()
    {
        // 配置读不出来时也要能启动，让用户有机会在设置界面里修好它。
        try
        {
            Config = _configStore.Load();
            var skipped = _configStore.SkippedServerCount;
            if (skipped > 0)
            {
                FatalError =
                    $"配置文件里有 {skipped} 台服务器没能读入（缺少 id / name / provider，或字段类型不对），"
                    + $"其余服务器照常工作。修好后重启即可：{_configStore.FilePath}";
            }
        }
        catch (Exception ex)
        {
            Config = new AppConfig();
            FatalError = $"配置文件读取失败，已按空配置启动：{ex.Message}";
        }

        VultrApiKey = SecretStore.GetVultrApiKey() ?? "";

        try
        {
            _store = new SqliteStore(AppPaths.DatabaseFile);
            _monitor = new TrafficMonitor(_store, Config, VultrApiKey);
        }
        catch (Exception ex)
        {
            FatalError = $"无法打开本地数据库：{ex.Message}";
        }

        // 注意别让异常从这个 async void 里逸出：未捕获异常会直接崩掉进程。
        // RefreshAsync 内部已经自己兜住了，这里再套一层是为了防止将来改动漏掉。
        _timer.Tick += async (_, _) =>
        {
            try { await RefreshAsync(); }
            catch (Exception ex) { ReportFailure(ex); }
        };
        ScheduleTimer();
    }

    /// <summary>
    /// 启动流程：先用本地数据把界面填满，再在后台发起真正的采集。
    /// 这样即使网络或 SSH 很慢，打开窗口也能立刻看到上次的数据。
    /// </summary>
    public async Task StartAsync()
    {
        if (_monitor is null) return;

        // 先读本地数据；读不出来也要继续往下走去采集，不能让界面卡在空白上。
        try
        {
            Statuses = await _monitor.StatusesAsync();
        }
        catch (Exception ex)
        {
            ReportFailure(ex);
        }
        StatusesChanged?.Invoke();
        await RefreshAsync();
    }

    public async Task RefreshAsync()
    {
        if (_monitor is null || IsRefreshing) return;

        IsRefreshing = true;
        StatusesChanged?.Invoke();
        try
        {
            Statuses = await _monitor.RefreshAllAsync(_lifetime.Token);
            LastRefreshAt = DateTime.UtcNow;
            RefreshError = null;
        }
        catch (OperationCanceledException)
        {
            // 退出时主动取消的，不是故障，也不该盖掉界面上已有的数据。
        }
        catch (Exception ex)
        {
            // 单台采集失败早在 TrafficMonitor 里就被隔离了，能到这里的是整体性故障
            // （库写不进去、磁盘满、配置在采集途中被改动）。按 S3 的约定：
            // 报出原因，但保留上一次成功的数据，不要崩掉进程。
            ReportFailure(ex);
        }
        finally
        {
            IsRefreshing = false;
            StatusesChanged?.Invoke();
        }
    }

    /// <summary>把整体性故障挂到界面上。</summary>
    private void ReportFailure(Exception ex)
    {
        RefreshError = $"刷新失败：{ex.Message}";
    }

    /// <summary>
    /// 测试单台服务器的采集。返回 null 表示成功。
    /// </summary>
    /// <param name="apiKey">设置窗口里当前编辑中的凭据，仅本次测试使用。</param>
    /// <remarks>
    /// 刻意<b>不落盘、不改动正在运行的配置</b>：「测试连接」是用来验证填得对不对的，
    /// 不该顺手把整份编辑中的配置提交掉 —— 否则用户点完测试再点 X 也放弃不了改动。
    /// </remarks>
    public async Task<string?> TestServerAsync(ServerConfig server, string apiKey)
    {
        if (_monitor is null) return "数据库未就绪";

        var saved = VultrApiKey;
        _monitor.SetVultrApiKey(string.IsNullOrEmpty(apiKey) ? null : apiKey);
        try
        {
            var error = await _monitor.RefreshOneAsync(server, DateTime.UtcNow, _lifetime.Token);
            Statuses = await _monitor.StatusesAsync();
            StatusesChanged?.Invoke();
            return error;
        }
        finally
        {
            // 草稿凭据只在这一次测试里有效，测完还给已保存的那个。
            _monitor.SetVultrApiKey(string.IsNullOrEmpty(saved) ? null : saved);
        }
    }

    /// <summary>用设置窗口编辑好的草稿整体替换当前配置并落盘。</summary>
    public void ApplyConfig(AppConfig config, string apiKey)
    {
        Config = config;
        VultrApiKey = apiKey;
        SaveConfig();
    }

    public void SaveConfig()
    {
        try
        {
            _configStore.Save(Config);
            SecretStore.SetVultrApiKey(string.IsNullOrEmpty(VultrApiKey) ? null : VultrApiKey);
        }
        catch (Exception ex)
        {
            MessageBox.Show($"保存配置失败：{ex.Message}", "VPS 流量",
                MessageBoxButton.OK, MessageBoxImage.Error);
            return;
        }

        _monitor?.UpdateConfig(Config);
        _monitor?.SetVultrApiKey(string.IsNullOrEmpty(VultrApiKey) ? null : VultrApiKey);
        ScheduleTimer();
        _ = RefreshAsync();
    }

    private void ScheduleTimer()
    {
        _timer.Stop();
        var minutes = Math.Max(5, Config.RefreshIntervalMinutes);
        _timer.Interval = TimeSpan.FromMinutes(minutes);
        _timer.Start();
    }

    // MARK: 窗口

    public void ShowMain()
    {
        if (_mainWindow is null || !_mainWindow.IsLoaded)
        {
            _mainWindow = new MainWindow(this);
            _mainWindow.Closed += (_, _) => _mainWindow = null;
        }
        Show(_mainWindow);
    }

    public void ShowSettings(Window? owner = null)
    {
        if (_settingsWindow is null || !_settingsWindow.IsLoaded)
        {
            _settingsWindow = new SettingsWindow(this);
            _settingsWindow.Closed += (_, _) => _settingsWindow = null;
            if (owner is not null) _settingsWindow.Owner = owner;
        }
        Show(_settingsWindow);
    }

    private static void Show(Window window)
    {
        window.Show();
        // 已经打开但被最小化或压在别的窗口下面时，要把它捞回最前面。
        if (window.WindowState == WindowState.Minimized) window.WindowState = WindowState.Normal;
        window.Activate();
    }

    /// <summary>用量比例最高的一台。比例相同时取列表里靠前的那台（与 macOS 端口径一致）。</summary>
    public ServerStatus? MostCritical => Statuses
        .Where(s => s.UsedFraction is not null)
        .OrderByDescending(s => s.UsedFraction)
        .FirstOrDefault();

    /// <summary>
    /// 托盘要反映的那台。优先用设置里指定的服务器；没指定、或指定的那台已经被删掉时，
    /// 回退到用量最紧张的一台 —— 这也是加这个设置之前的行为。
    /// </summary>
    public ServerStatus? MenuBarStatus
    {
        get
        {
            if (!string.IsNullOrEmpty(Config.MenuBarServerId))
            {
                var pinned = Statuses.FirstOrDefault(s => s.Server.Id == Config.MenuBarServerId);
                if (pinned is not null) return pinned;
            }
            return MostCritical ?? Statuses.FirstOrDefault();
        }
    }


    public bool HasAnyError => Statuses.Any(s => s.LastError is not null);

    public async ValueTask DisposeAsync()
    {
        _timer.Stop();

        // 先取消并等在途采集收敛，再关连接 —— 否则 RefreshAllAsync 可能还在用
        // 同一个 SqliteConnection，dispose 掉它会抛 ObjectDisposedException。
        await _lifetime.CancelAsync();
        for (var i = 0; i < 50 && IsRefreshing; i++)
        {
            await Task.Delay(100).ConfigureAwait(false);
        }
        _lifetime.Dispose();

        if (_store is not null) await _store.DisposeAsync();
    }
}
