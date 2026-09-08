namespace VpsQuota;

using System.Drawing;
using System.Windows;
using VpsQuota.Models;
using VpsQuota.UI;
using Forms = System.Windows.Forms;

/// <summary>
/// 托盘常驻应用入口。对应 macOS 端的 MenuBarExtra。
/// </summary>
public partial class App : Application
{
    private AppState? _state;
    private Forms.NotifyIcon? _tray;
    private Icon? _currentIcon;

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
        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add("显示面板", null, (_, _) => _state?.ShowMain());
        menu.Items.Add("立即刷新", null, async (_, _) =>
        {
            if (_state is not null) await _state.RefreshAsync();
        });
        menu.Items.Add("设置…", null, (_, _) => _state?.ShowSettings());
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("退出", null, (_, _) => Shutdown());

        _tray = new Forms.NotifyIcon
        {
            Visible = true,
            Text = "VPS 流量",
            ContextMenuStrip = menu,
        };
        // 单击（而非右键）直接打开面板，和 macOS 端点菜单栏图标的手感一致。
        _tray.MouseClick += (_, args) =>
        {
            if (args.Button == Forms.MouseButtons.Left) _state?.ShowMain();
        };

        UpdateTray();
    }

    private void UpdateTray()
    {
        if (_tray is null || _state is null) return;

        Dispatcher.Invoke(() =>
        {
            var status = _state.MostCritical;
            var severity = _state.HasAnyError || _state.FatalError is not null
                ? Severity.Unknown
                : status?.Severity ?? Severity.Unknown;

            var fraction = status?.UsedFraction;
            var previous = _currentIcon;
            _currentIcon = BuildIcon(severity, fraction);
            _tray.Icon = _currentIcon;
            // GetHicon 分配的是非托管句柄，换掉之后必须显式销毁，否则每次刷新都漏一个。
            previous?.Dispose();

            _tray.Text = status is null
                ? "VPS 流量 —— 尚无数据"
                : $"{status.Server.Name}　{Core.ByteFormat.GB(status.UsedGB)}" +
                  (status.QuotaGB > 0 ? $" / {Core.ByteFormat.GB(status.QuotaGB)}" : "");
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
