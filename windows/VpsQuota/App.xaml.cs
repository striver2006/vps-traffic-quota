namespace VpsQuota;

using System.Drawing;
// Mutex / CancellationToken 在 System.Threading 里。必须显式 using：
// XamlPreCompile 生成的 wpftmp 项目不继承 ImplicitUsings，见 csproj 里的说明。
using System.Threading;
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

    /// <summary>单实例闸门。第二次启动时拿不到它，说明已经有一个在跑。</summary>
    private Mutex? _singleInstance;

    /// <summary>
    /// 接收唤起广播的隐藏窗口。刻意是普通的顶层窗口而不是 message-only 窗口 ——
    /// HWND_BROADCAST 只送到顶层窗口，message-only 的收不到。
    /// </summary>
    private System.Windows.Interop.HwndSource? _messageSink;

    /// <summary>
    /// 唤起已有实例用的广播消息。Windows 常把新来的托盘图标塞进溢出区，
    /// 用户找不到图标就再双击一次 exe —— 那样只会起第二个进程，
    /// 两套定时器、两个连接同时写同一个 SQLite。这里把它变成"把主窗口拿出来"。
    /// </summary>
    private static readonly uint ShowMainMessage =
        RegisterWindowMessage("VpsQuota.ShowMainWindow.9C1E4F");

    /// <summary>悬停时浮出的面板。取代了系统 tooltip，一直复用同一个实例。</summary>
    private TrayPopupWindow? _popup;

    /// <summary>最后一次收到托盘图标 MouseMove 的时刻，用来判断鼠标是否已经离开图标。</summary>
    private DateTime _lastTrayHoverAt;

    /// <summary>最后一次 MouseMove 时的指针屏幕坐标（物理像素）。</summary>
    /// <remarks>
    /// 托盘图标只在指针移动时才发 MouseMove，静止悬停不会再来事件。
    /// 只靠"多久没收到事件"判断离开，手停在图标上不动也会被误判成已离开、
    /// 面板收起后手一抖又立刻弹出，看起来就是一闪一闪。
    /// 而指针要离开图标就必须先移动 —— 坐标和最后一次在图标上时完全一致，
    /// 就能证明它还悬停在原处。
    /// </remarks>
    private System.Drawing.Point _lastTrayPointerPos;

    /// <summary>面板是否被点击固定。固定时不跟随鼠标自动收起，再点图标或点面板外才收。</summary>
    private bool _popupPinned;

    /// <summary>固定期间挂上的低级鼠标钩子：面板不抢焦点，点在外面只能靠它发现。</summary>
    private IntPtr _clickHook;

    /// <summary>钩子回调的委托必须强引用，被 GC 收走钩子就失效了。</summary>
    private LowLevelMouseProc? _clickHookProc;

    /// <summary>
    /// 面板从"固定"状态收起的时刻。收起它的那次点击还会传给图标本身，
    /// 紧跟着的 MouseClick 不能当成新一轮"打开"，否则固定面板永远关不掉。
    /// </summary>
    private DateTime _popupUnpinnedAt = DateTime.MinValue;

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

        // 未捕获异常至少要能说明原因，而不是让进程无声消失。
        DispatcherUnhandledException += (_, args) =>
        {
            MessageBox.Show($"发生了未处理的错误：\n\n{args.Exception.Message}",
                "VPS 流量", MessageBoxButton.OK, MessageBoxImage.Error);
            args.Handled = true;
        };

        _singleInstance = new Mutex(initiallyOwned: true, "VpsQuota.SingleInstance", out var isFirst);
        if (!isFirst)
        {
            // 已经有一个在跑：让它把主窗口拿到前面来，自己安静退出。
            PostMessage(HWND_BROADCAST, ShowMainMessage, IntPtr.Zero, IntPtr.Zero);
            Shutdown();
            return;
        }

        _state = new AppState();
        _state.StatusesChanged += UpdateTray;

        InstallMessageSink();
        SetupTray();

        if (_state.FatalError is { } fatal)
        {
            MessageBox.Show(fatal, "VPS 流量", MessageBoxButton.OK, MessageBoxImage.Warning);
        }

        // 没有任何服务器时直接把设置窗口推到用户面前，否则托盘图标看起来像是坏了。
        if (_state.Config.Servers.Count == 0) _state.ShowSettings();

        await _state.StartAsync();
    }

    /// <summary>装上接收「唤起主窗口」广播的隐藏窗口。</summary>
    private void InstallMessageSink()
    {
        var parameters = new System.Windows.Interop.HwndSourceParameters("VpsQuotaMessageSink")
        {
            Width = 0,
            Height = 0,
            WindowStyle = 0,
        };
        _messageSink = new System.Windows.Interop.HwndSource(parameters);
        _messageSink.AddHook((IntPtr hwnd, int msg, IntPtr w, IntPtr l, ref bool handled) =>
        {
            if ((uint)msg == ShowMainMessage)
            {
                ShowMainWindow();
                handled = true;
            }
            return IntPtr.Zero;
        });
    }

    private void SetupTray()
    {
        // 首行是只读摘要，把"剩余多少 GB"直接摆在菜单上，不用先展开面板。
        _summaryItem = new Forms.ToolStripMenuItem("VPS 流量") { Enabled = false };

        _summarySeparator = new Forms.ToolStripSeparator();

        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add(_summaryItem);
        menu.Items.Add(_summarySeparator);
        menu.Items.Add("打开主界面", null, (_, _) => ShowMainWindow());
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
        // 单击：固定/收起面板。主界面从右键菜单或面板里的按钮进 ——
        // 托盘单击直接弹主窗口太重，也和悬停面板内容重复。
        _tray.MouseClick += (_, args) =>
        {
            if (args.Button == Forms.MouseButtons.Left) TogglePinnedPopup();
        };
        // 托盘图标只有 MouseMove，没有 MouseEnter/Leave：
        // 进入靠它触发，离开靠 _hoverTimer 发现"一段时间没再收到 MouseMove"。
        _tray.MouseMove += (_, _) =>
        {
            // 刚用点击收起固定面板时，指针多半还停在图标上，抖动 1px 就会走到这里
            // 把面板以悬停模式重新弹出来 —— 用户看到的就是"点了关不掉"。
            // 与 MouseClick 用同一个时间窗，让这一下点击真正生效。
            if ((DateTime.UtcNow - _popupUnpinnedAt).TotalMilliseconds < 400) return;

            _lastTrayHoverAt = DateTime.UtcNow;
            _lastTrayPointerPos = Forms.Cursor.Position;
            ShowPopup();
        };

        _hoverTimer.Tick += (_, _) => HidePopupIfPointerAway();

        UpdateTray();
    }

    // MARK: 悬停面板

    private void ShowPopup(bool pinned = false)
    {
        if (_state is null) return;

        if (_popup is null)
        {
            _popup = new TrayPopupWindow(_state);
            // 面板被关掉（而不是隐藏）之后就不能再 Show 了，置空好让下次重建。
            _popup.Closed += (_, _) => _popup = null;
            // 收起路径有好几条（悬停超时、点外面、面板按钮里自己 Hide），
            // 固定态和钩子统一在这里清，漏一条就会留一个全局鼠标钩子。
            _popup.IsVisibleChanged += (_, e) =>
            {
                if ((bool)e.NewValue) return;
                if (_popupPinned) _popupUnpinnedAt = DateTime.UtcNow;
                _popupPinned = false;
                UninstallClickHook();
            };
        }
        if (!_popup.IsVisible) _popup.ShowNearTray();
        // 悬停期间鼠标一动就会再进这里，不能把已经固定的面板降回悬停模式。
        if (pinned) _popupPinned = true;

        if (_popupPinned)
        {
            _hoverTimer.Stop();
            InstallClickHook();
        }
        else
        {
            _hoverTimer.Start();
        }
    }

    private void HidePopupIfPointerAway()
    {
        if (_popup is null || !_popup.IsVisible)
        {
            _hoverTimer.Stop();
            return;
        }
        // 固定的面板不跟随鼠标：只有再点图标或点在外面才收。
        if (_popupPinned)
        {
            _hoverTimer.Stop();
            return;
        }
        // 鼠标已经移进面板里了 —— 用户正要点按钮，不能收。
        if (_popup.IsMouseOver) return;
        // 还在图标上（MouseMove 仍在源源不断地来）也不收。
        if ((DateTime.UtcNow - _lastTrayHoverAt).TotalMilliseconds < 500) return;
        // 事件静默但指针坐标分毫未动 —— 它不可能不移动就离开图标，静止悬停不是离开。
        if (Forms.Cursor.Position == _lastTrayPointerPos) return;

        HidePopup();
    }

    private void HidePopup()
    {
        _hoverTimer.Stop();
        // 固定态和鼠标钩子在 IsVisibleChanged 里统一清。
        _popup?.Hide();
    }

    /// <summary>单击图标：第一次固定面板，再点一次收起。</summary>
    private void TogglePinnedPopup()
    {
        if (_popup is { IsVisible: true } && _popupPinned)
        {
            HidePopup();
            return;
        }
        // 低级钩子先于图标自己的 MouseClick 收起面板，那次点击紧接着传到这里，
        // 不能当成新的"打开"。悬停自动收起不记这个时间戳，不受影响。
        if ((DateTime.UtcNow - _popupUnpinnedAt).TotalMilliseconds < 400) return;
        ShowPopup(pinned: true);
    }

    private void InstallClickHook()
    {
        if (_clickHook != IntPtr.Zero) return;
        _clickHookProc ??= ClickHookProc;
        _clickHook = SetWindowsHookEx(WH_MOUSE_LL, _clickHookProc!, GetModuleHandle(null), 0);
    }

    private void UninstallClickHook()
    {
        if (_clickHook == IntPtr.Zero) return;
        var hook = _clickHook;
        _clickHook = IntPtr.Zero;
        UnhookWindowsHookEx(hook);
    }

    /// <summary>
    /// 固定期间的全局鼠标监视：按下发生在面板外任何地方（含图标、别的窗口、桌面）
    /// 就收起面板。点击本身照常传给目标，这里只旁观不改写。
    /// </summary>
    private IntPtr ClickHookProc(int nCode, IntPtr wParam, IntPtr lParam)
    {
        const uint leftDown = 0x0201, rightDown = 0x0204, middleDown = 0x0207, xDown = 0x020B;
        var message = unchecked((uint)wParam.ToInt64());
        var isDown = nCode >= 0
            && (message == leftDown || message == rightDown
                || message == middleDown || message == xDown);
        if (isDown)
        {
            // MSLLHOOKSTRUCT 的第一个成员就是 POINT，只读坐标不必整块解析。
            var point = System.Runtime.InteropServices.Marshal
                .PtrToStructure<NativePoint>(lParam);
            Dispatcher.BeginInvoke(() =>
            {
                if (_popup is not { IsVisible: true }) return;
                // 全程留在物理像素里比较。PerMonitorV2 下 Window.Left/Top 是按
                // "面板自己那块屏"的缩放折算出来的 WPF 单位，拿它的 transform 去换算
                // 另一块屏（缩放不同）上的点会算错 —— 点在别的显示器上有可能被误判成
                // 落在面板内，面板就收不起来。GetWindowRect 直接给物理矩形，不做跨屏换算。
                var hwnd = new System.Windows.Interop.WindowInteropHelper(_popup).Handle;
                if (hwnd == IntPtr.Zero || !GetWindowRect(hwnd, out var bounds)) return;
                // 命中范围往外放宽一点，贴着面板边缘的点击不算"点在外面"。
                // 这圈容差是面板自己屏幕上的视觉尺寸，按该窗口的 DPI 折算成物理像素。
                var dpi = GetDpiForWindow(hwnd);
                var scale = (dpi == 0 ? 96u : dpi) / 96.0;
                var pad = (int)(16 * scale);
                if (point.X >= bounds.Left - pad && point.X <= bounds.Right + pad
                    && point.Y >= bounds.Top - pad && point.Y <= bounds.Bottom + pad)
                {
                    return;
                }
                HidePopup();
            });
        }
        return CallNextHookEx(_clickHook, nCode, wParam, lParam);
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
            // 只看这一台自己的状态。以前用的是全局 HasAnyError —— 三台里有一台 SSH 不通，
            // 指定显示的那台明明已经 92% 也会被画成灰色，
            // "不用点开就能感知严重程度"恰恰在最需要的时候失效。
            // 整体性故障走右键菜单的摘要行与浮窗，不再抢图标的颜色。
            var severity = _state.FatalError is not null || status?.LastError is not null
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

    private const int WH_MOUSE_LL = 14;

    [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GetModuleHandle(string? moduleName);

    [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(
        int idHook, LowLevelMouseProc callback, IntPtr module, uint threadId);

    [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnhookWindowsHookEx(IntPtr hook);

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(
        IntPtr hook, int nCode, IntPtr wParam, IntPtr lParam);

    [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetWindowRect(IntPtr window, out NativeRect rect);

    /// <summary>窗口所在显示器的 DPI。PerMonitorV2 下每块屏可以不一样。</summary>
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr window);

    // 单实例唤起：注册一个全应用唯一的消息号，第二个实例广播它，第一个实例收到后弹主窗口。
    private static readonly IntPtr HWND_BROADCAST = new(0xFFFF);

    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet =
        System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
    private static extern uint RegisterWindowMessage(string message);

    [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
    private static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);

    private delegate IntPtr LowLevelMouseProc(int nCode, IntPtr wParam, IntPtr lParam);

    [System.Runtime.InteropServices.StructLayout(
        System.Runtime.InteropServices.LayoutKind.Sequential)]
    private struct NativePoint
    {
        public int X;
        public int Y;
    }

    /// <summary>Win32 RECT：物理像素，right/bottom 是开区间边界。</summary>
    [System.Runtime.InteropServices.StructLayout(
        System.Runtime.InteropServices.LayoutKind.Sequential)]
    private struct NativeRect
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    protected override async void OnExit(ExitEventArgs e)
    {
        _hoverTimer.Stop();
        UninstallClickHook();
        _popup?.Close();

        if (_tray is not null)
        {
            // 不显式隐藏的话，退出后托盘里会留下一个要鼠标划过才消失的幽灵图标。
            _tray.Visible = false;
            _tray.Dispose();
        }
        _currentIcon?.Dispose();
        _messageSink?.Dispose();

        if (_state is not null) await _state.DisposeAsync();

        _singleInstance?.Dispose();
        base.OnExit(e);
    }
}
