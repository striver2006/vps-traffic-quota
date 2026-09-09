namespace VpsQuota.UI;

using System.Windows;
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

        FatalText.Text = _state.FatalError ?? "";
        FatalText.Visibility = _state.FatalError is null ? Visibility.Collapsed : Visibility.Visible;

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
        UpdateLayout();
        MoveToTrayCorner(ActualWidth, ActualHeight);
    }

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
