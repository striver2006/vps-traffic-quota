namespace VpsQuota;

using System.Drawing;
using System.Windows;
using System.Windows.Threading;
using VpsQuota.Models;
using VpsQuota.UI;
using Forms = System.Windows.Forms;

/// <summary>
/// 托盘常驻应用入口。对应 macOS 端的菜单栏状态项。
/// </summary>
public partial class App : Application
{
    private AppState? _state;
    private Forms.NotifyIcon? _tray;
    private Icon? _currentIcon;

    /// <summary>悬停时浮出的面板。取代了系统 tooltip，一直复用同一个实例。</summary>
    private TrayPopupWindow? _popup;

    /// <summary>最后一次收到托盘图标 MouseMove 的时刻，用来判断鼠标是否已经离开图标。</summary>
    private DateTime _lastTrayHoverAt;

    /// <summary>面板的收起判定。托盘图标没有"鼠标移出"事件，只能轮询。</summary>
    private readonly DispatcherTimer _hoverTimer = new()
    {
        Interval = TimeSpan.FromMilliseconds(250),
    };

    /// <summary>右键菜单顶部那行只读摘要：所选服务器的剩余流量。</summary>
    private Forms.ToolStripMenuItem? _summaryItem;

    /// <summary>摘要行下面那条分隔线。摘要藏起来时它也得跟着藏，否则菜单顶上会多出一道线。</summary>
    private Forms.ToolStripSeparator? _summarySeparator;

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        _state = new AppState();
        _state.StatusesChanged += UpdateTray;

        SetupTray();

        if (_state.FatalError is { } fatal)
        {
            MessageBox.Show(fatal, "VPS 流量", MessageBoxButton.OK, MessageBoxImage.Warning);
        }

        // 没有任何服务器时直接把设置窗口推到用户面前，否则托盘图标看起来像是坏了。
        if (_state.Config.Servers.Count == 0) _state.ShowSettings();

        await _state.StartAsync();
    }

    private void SetupTray()
    {
        // 首行是只读摘要，把"剩余多少 GB"直接摆在菜单上，不用先展开面板。
        _summaryItem = new Forms.ToolStripMenuItem("VPS 流量") { Enabled = false };

        _summarySeparator = new Forms.ToolStripSeparator();

        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add(_summaryItem);
        menu.Items.Add(_summarySeparator);
        menu.Items.Add("显示面板", null, (_, _) => ShowMainWindow());
        menu.Items.Add("立即刷新", null, async (_, _) =>
        {
            if (_state is not null) await _state.RefreshAsync();
        });
        menu.Items.Add("设置…", null, (_, _) => { HidePopup(); _state?.ShowSettings(); });
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("退出", null, (_, _) => Shutdown());

        _tray = new Forms.NotifyIcon
        {
            Visible = true,
            // 刻意留空：Text 就是系统 tooltip，而这里改用自己的浮动面板，
            // 两个一起弹会互相盖住。
            Text = "",
            ContextMenuStrip = menu,
        };
        // 单击（而非右键）直接打开主窗口，和 macOS 端点菜单栏图标的手感一致。
        _tray.MouseClick += (_, args) =>
        {
            if (args.Button == Forms.MouseButtons.Left) ShowMainWindow();
        };
        // 托盘图标只有 MouseMove，没有 MouseEnter/Leave：
        // 进入靠它触发，离开靠 _hoverTimer 发现"一段时间没再收到 MouseMove"。
        _tray.MouseMove += (_, _) =>
        {
            _lastTrayHoverAt = DateTime.UtcNow;
            ShowPopup();
        };

        _hoverTimer.Tick += (_, _) => HidePopupIfPointerAway();

        UpdateTray();
    }

    // MARK: 悬停面板

    private void ShowPopup()
    {
        if (_state is null) return;

        if (_popup is null)
        {
            _popup = new TrayPopupWindow(_state);
            // 面板被关掉（而不是隐藏）之后就不能再 Show 了，置空好让下次重建。
            _popup.Closed += (_, _) => _popup = null;
        }
        if (!_popup.IsVisible) _popup.ShowNearTray();
        _hoverTimer.Start();
    }

    private void HidePopupIfPointerAway()
    {
        if (_popup is null || !_popup.IsVisible)
        {
            _hoverTimer.Stop();
            return;
        }
        // 鼠标已经移进面板里了 —— 用户正要点按钮，不能收。
        if (_popup.IsMouseOver) return;
        // 还在图标上（MouseMove 仍在源源不断地来）也不收。
        if ((DateTime.UtcNow - _lastTrayHoverAt).TotalMilliseconds < 500) return;

        HidePopup();
    }

    private void HidePopup()
    {
        _hoverTimer.Stop();
        _popup?.Hide();
    }

    private void ShowMainWindow()
    {
        HidePopup();
        _state?.ShowMain();
    }

    private void UpdateTray()
    {
        if (_tray is null || _state is null) return;

        Dispatcher.Invoke(() =>
        {
            // 图标跟着"设置里指定要显示的那台"走，和菜单上的数字说的是同一台。
            var status = _state.MenuBarStatus;
            var severity = _state.HasAnyError || _state.FatalError is not null
                ? Severity.Unknown
                : status?.Severity ?? Severity.Unknown;

            var fraction = status?.UsedFraction;
            var previous = _currentIcon;
            _currentIcon = BuildIcon(severity, fraction);
            _tray.Icon = _currentIcon;
            // GetHicon 分配的是非托管句柄，换掉之后必须显式销毁，否则每次刷新都漏一个。
            previous?.Dispose();

            // 「不显示剩余流量」在 Windows 上就是把这行摘要连同分隔线一起藏掉。
            var showsSummary = _state.Config.MenuBarShowsRemaining;
            if (_summaryItem is not null) _summaryItem.Visible = showsSummary;
            if (_summarySeparator is not null) _summarySeparator.Visible = showsSummary;

            if (_summaryItem is not null && showsSummary)
            {
                // ToolStrip 会把 & 当成助记符前缀吃掉，服务器名里若有它得先转义。
                var name = status?.Server.Name.Replace("&", "&&") ?? "";
                _summaryItem.Text = status is null
                    ? "尚无数据"
                    : status.RemainingGB is { } remaining
                        ? $"{name}　剩余 {Core.ByteFormat.GB(remaining)}"
                          + $" / {Core.ByteFormat.GB(status.QuotaGB)}"
                        : $"{name}　已用 {Core.ByteFormat.GB(status.UsedGB)}　配额未知";
            }
        });
    }

    /// <summary>
    /// 运行时画一个托盘图标：底部是一格格的柱状条，上方按用量比例填充。
    ///
    /// 运行时绘制而不是打包 .ico，是为了让颜色能跟着严重程度变 ——
    /// 不展开菜单也能一眼看出有没有逼近配额。
    /// </summary>
    private static Icon BuildIcon(Severity severity, double? fraction)
    {
        const int size = 32;
        using var bitmap = new Bitmap(size, size);
        using (var g = Graphics.FromImage(bitmap))
        {
            g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            g.Clear(Color.Transparent);

            var color = Theme.DrawingColorFor(severity);
            using var track = new SolidBrush(Color.FromArgb(70, color));
            using var fill = new SolidBrush(color);

            // 三根柱子，整体表意"流量"；填充高度表示用量比例。
            var ratio = Math.Clamp(fraction ?? 0, 0, 1);
            int[] heights = { 14, 22, 28 };
            for (var i = 0; i < heights.Length; i++)
            {
                var x = 4 + i * 9;
                var full = heights[i];
                var top = size - 2 - full;

                g.FillRectangle(track, x, top, 7, full);
                var filled = (int)Math.Round(full * ratio);
                if (filled > 0) g.FillRectangle(fill, x, size - 2 - filled, 7, filled);
            }
        }

        var handle = bitmap.GetHicon();
        try
        {
            // FromHandle 不接管句柄所有权，必须复制一份再销毁原句柄，避免 GDI 句柄泄漏。
            using var temp = Icon.FromHandle(handle);
            return (Icon)temp.Clone();
        }
        finally
        {
            DestroyIcon(handle);
        }
    }

    [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
    private static extern bool DestroyIcon(IntPtr handle);

    protected override async void OnExit(ExitEventArgs e)
    {
        _hoverTimer.Stop();
        _popup?.Close();

        if (_tray is not null)
        {
            // 不显式隐藏的话，退出后托盘里会留下一个要鼠标划过才消失的幽灵图标。
            _tray.Visible = false;
            _tray.Dispose();
        }
        _currentIcon?.Dispose();

        if (_state is not null) await _state.DisposeAsync();
        base.OnExit(e);
    }
}
