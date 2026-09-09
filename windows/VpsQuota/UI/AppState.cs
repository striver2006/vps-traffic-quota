namespace VpsQuota.UI;

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

    public event Action? StatusesChanged;

    public AppState()
    {
        // 配置读不出来时也要能启动，让用户有机会在设置界面里修好它。
        try { Config = _configStore.Load(); }
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

        _timer.Tick += async (_, _) => await RefreshAsync();
        ScheduleTimer();
    }

    /// <summary>
    /// 启动流程：先用本地数据把界面填满，再在后台发起真正的采集。
    /// 这样即使网络或 SSH 很慢，打开窗口也能立刻看到上次的数据。
    /// </summary>
    public async Task StartAsync()
    {
        if (_monitor is null) return;
        Statuses = await _monitor.StatusesAsync();
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
            Statuses = await _monitor.RefreshAllAsync();
            LastRefreshAt = DateTime.UtcNow;
        }
        finally
        {
            IsRefreshing = false;
            StatusesChanged?.Invoke();
        }
    }

    /// <summary>测试单台服务器的采集。返回 null 表示成功。</summary>
    public async Task<string?> TestServerAsync(ServerConfig server)
    {
        if (_monitor is null) return "数据库未就绪";

        // 测试用的是当前编辑中的凭据，先同步过去，否则测的还是旧 Key。
        _monitor.SetVultrApiKey(string.IsNullOrEmpty(VultrApiKey) ? null : VultrApiKey);
        var error = await _monitor.RefreshOneAsync(server, DateTime.UtcNow);
        Statuses = await _monitor.StatusesAsync();
        StatusesChanged?.Invoke();
        return error;
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

    /// <summary>用量比例最高的一台。</summary>
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
        if (_store is not null) await _store.DisposeAsync();
    }
}
