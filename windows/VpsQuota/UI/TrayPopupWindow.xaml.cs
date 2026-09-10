namespace VpsQuota.UI;

// Runtime.InteropServices / Windows.Interop 都必须显式 using：
// XamlPreCompile 生成的 wpftmp 项目不继承 ImplicitUsings，见 csproj 里的说明。
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using VpsQuota.Core;

/// <summary>
/// 鼠标移到托盘图标上时浮出的面板，对应 macOS 端菜单栏图标下的那块弹出内容。
/// </summary>
/// <remarks>
/// 它取代了系统自带的托盘 tooltip（<c>NotifyIcon.Text</c> 已被清空）：
/// tooltip 只能显示一行纯文本，放不下进度条和多台服务器的明细。
///
/// 窗口是 <c>ShowActivated="False"</c> 的 —— 悬停就抢焦点会打断用户正在别处的输入。
/// 显示与隐藏由 <see cref="App"/> 里的悬停计时器驱动，这里只负责内容和定位。
/// </remarks>
public partial class TrayPopupWindow : Window
{
    private readonly AppState _state;

    public TrayPopupWindow(AppState state)
    {
        InitializeComponent();
        _state = state;
        _state.StatusesChanged += OnStatusesChanged;
        Render();
    }

    protected override void OnClosed(EventArgs e)
    {
        _state.StatusesChanged -= OnStatusesChanged;
        base.OnClosed(e);
    }

    private void OnStatusesChanged() => Dispatcher.Invoke(Render);

    public void Render()
    {
        var pinnedId = _state.MenuBarStatus?.Server.Id;
        var rows = _state.Statuses
            .Select(s => new ServerRowViewModel(s) { IsPinnedToTray = s.Server.Id == pinnedId })
            .ToList();

        Rows.ItemsSource = rows;
        EmptyPanel.Visibility = rows.Count == 0 ? Visibility.Visible : Visibility.Collapsed;

        // 启动期的致命错误优先；没有的话再显示最近一次整体性刷新故障。
        var fatal = _state.FatalError ?? _state.RefreshError;
        FatalText.Text = fatal ?? "";
        FatalText.Visibility = fatal is null ? Visibility.Collapsed : Visibility.Visible;

        StatusText.Text = _state.IsRefreshing
            ? "正在采集…"
            : _state.LastRefreshAt is { } at
                ? ByteFormat.RelativeTime(at, DateTime.UtcNow)
                : "尚未刷新";
        RefreshButton.IsEnabled = !_state.IsRefreshing;
    }

    /// <summary>刷新内容、贴到托盘所在的那个屏幕角，然后显示出来。</summary>
    public void ShowNearTray()
    {
        Render();

        // 先量一遍再定位：SizeToContent 的窗口在 Show() 之前 ActualWidth 还是 0，
        // 直接 Show 会先在屏幕左上角闪一下再跳到位。
        Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        MoveToTrayCorner(DesiredSize.Width, DesiredSize.Height);

        Show();
        // Measure 出来的尺寸和真正排完版的可能差几个像素，落定后再校准一次。
        // 这一次走物理像素：窗口已经有 HWND 了，可以直接问系统"托盘在哪块屏"，
        // 绕开 WPF 逻辑单位在多显示器混合缩放下的换算问题。
        UpdateLayout();
        if (!SnapToTrayCornerNative()) MoveToTrayCorner(ActualWidth, ActualHeight);
    }

    /// <summary>
    /// 用物理像素把窗口贴到<b>托盘所在那块屏</b>的角上。成功返回 true。
    /// </summary>
    /// <remarks>
    /// <see cref="SystemParameters.WorkArea"/> 只返回主显示器的工作区 ——
    /// 任务栏在副屏时，按它算出来的位置会把面板甩到主屏角落。
    /// 这里改用指针所在的显示器（悬停触发时指针必定在托盘图标上），
    /// 并且全程用物理像素 + SetWindowPos，与 App 里那个低级鼠标钩子的坐标口径一致。
    /// </remarks>
    private bool SnapToTrayCornerNative()
    {
        var hwnd = new WindowInteropHelper(this).Handle;
        if (hwnd == IntPtr.Zero) return false;
        if (!GetCursorPos(out var cursor)) return false;

        var monitor = MonitorFromPoint(cursor, MONITOR_DEFAULTTONEAREST);
        if (monitor == IntPtr.Zero) return false;

        var info = new MonitorInfo { Size = Marshal.SizeOf<MonitorInfo>() };
        if (!GetMonitorInfo(monitor, ref info)) return false;
        if (!GetWindowRect(hwnd, out var window)) return false;

        var width = window.Right - window.Left;
        var height = window.Bottom - window.Top;
        var work = info.Work;
        var full = info.Monitor;
        const int gap = 2;

        int left, top;
        // 与 MoveToTrayCorner 同一套推断：工作区哪条边被推进来，任务栏就在哪一侧。
        if (work.Top > full.Top)
        {
            left = work.Right - width - gap;
            top = work.Top + gap;
        }
        else if (work.Left > full.Left)
        {
            left = work.Left + gap;
            top = work.Bottom - height - gap;
        }
        else
        {
            left = work.Right - width - gap;
            top = work.Bottom - height - gap;
        }

        left = Math.Clamp(left, work.Left, Math.Max(work.Left, work.Right - width));
        top = Math.Clamp(top, work.Top, Math.Max(work.Top, work.Bottom - height));

        return SetWindowPos(hwnd, IntPtr.Zero, left, top, 0, 0,
                            SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
    }

    private const uint MONITOR_DEFAULTTONEAREST = 2;
    private const uint SWP_NOSIZE = 0x0001;
    private const uint SWP_NOZORDER = 0x0004;
    private const uint SWP_NOACTIVATE = 0x0010;

    [StructLayout(LayoutKind.Sequential)]
    private struct NativePoint
    {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeRect
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MonitorInfo
    {
        public int Size;
        public NativeRect Monitor;
        public NativeRect Work;
        public uint Flags;
    }

    [DllImport("user32.dll")]
    private static extern bool GetCursorPos(out NativePoint point);

    [DllImport("user32.dll")]
    private static extern IntPtr MonitorFromPoint(NativePoint point, uint flags);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetWindowRect(IntPtr window, out NativeRect rect);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetWindowPos(
        IntPtr window, IntPtr insertAfter, int x, int y, int cx, int cy, uint flags);

    /// <summary>
    /// 把窗口挪到任务栏通知区域所在的那个屏幕角。
    /// </summary>
    /// <remarks>
    /// 通过工作区与整屏的差值反推任务栏停靠在哪一边 —— 托盘总是在任务栏靠外的一端。
    /// 不用鼠标坐标：那是物理像素，在多显示器不同缩放时换算成 WPF 单位很容易错位。
    /// </remarks>
    private void MoveToTrayCorner(double width, double height)
    {
        var work = SystemParameters.WorkArea;
        const double gap = 2;   // 面板自带 14 的投影留白，这里只补一点点

        // 工作区顶边被推下来 → 任务栏在上 → 托盘在右上；
        // 左边被推进来 → 任务栏在左 → 托盘在左下；其余（含默认的下边、右边）→ 右下。
        if (work.Top > 0)
        {
            Left = work.Right - width - gap;
            Top = work.Top + gap;
        }
        else if (work.Left > 0)
        {
            Left = work.Left + gap;
            Top = work.Bottom - height - gap;
        }
        else
        {
            Left = work.Right - width - gap;
            Top = work.Bottom - height - gap;
        }

        // 面板比工作区还大时（超小屏 + 一堆服务器）宁可顶着左上角，也不能整块滑出屏幕外。
        Left = Math.Clamp(Left, work.Left, Math.Max(work.Left, work.Right - width));
        Top = Math.Clamp(Top, work.Top, Math.Max(work.Top, work.Bottom - height));
    }

    private void OnOpenMainClick(object sender, RoutedEventArgs e)
    {
        Hide();
        _state.ShowMain();
    }

    private async void OnRefreshClick(object sender, RoutedEventArgs e) =>
        await _state.RefreshAsync();

    private void OnSettingsClick(object sender, RoutedEventArgs e)
    {
        Hide();
        _state.ShowSettings();
    }
}
