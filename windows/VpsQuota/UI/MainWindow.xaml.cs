namespace VpsQuota.UI;

using System.Windows;
using System.Windows.Controls;
using VpsQuota.Core;
using VpsQuota.Models;

/// <summary>主窗口：左侧服务器列表，右侧选中项的详情与趋势图。</summary>
public partial class MainWindow : Window
{
    private readonly AppState _state;

    public MainWindow(AppState state)
    {
        InitializeComponent();
        _state = state;
        _state.StatusesChanged += OnStatusesChanged;
        Render();
    }

    protected override void OnClosed(EventArgs e)
    {
        // 主窗口只是托盘应用的一个视图，关掉它不应该带走事件订阅。
        _state.StatusesChanged -= OnStatusesChanged;
        base.OnClosed(e);
    }

    private void OnStatusesChanged() => Dispatcher.Invoke(Render);

    private void Render()
    {
        var selectedId = (ServerList.SelectedItem as ServerRowViewModel)?.Id;

        var rows = _state.Statuses.Select(s => new ServerRowViewModel(s)).ToList();
        ServerList.ItemsSource = rows;

        // 刷新会重建整个列表，这里把选中项还原回去，否则每次刷新右侧详情都会跳走。
        ServerList.SelectedItem =
            rows.FirstOrDefault(r => r.Id == selectedId) ?? rows.FirstOrDefault();

        StatusText.Text = _state.IsRefreshing
            ? "正在采集…"
            : _state.LastRefreshAt is { } at
                ? $"上次刷新：{ByteFormat.RelativeTime(at, DateTime.UtcNow)}"
                : "尚未刷新";
        RefreshButton.IsEnabled = !_state.IsRefreshing;

        RenderDetail((ServerList.SelectedItem as ServerRowViewModel)?.Status);
    }

    private void RenderDetail(ServerStatus? status)
    {
        if (status is null)
        {
            DetailPanel.Visibility = Visibility.Hidden;
            Chart.Update(null);
            return;
        }

        DetailPanel.Visibility = Visibility.Visible;
        DetailName.Text = status.Server.Name;

        DetailUsed.Text = ByteFormat.GB(status.UsedGB);
        DetailUsed.Foreground = Theme.BrushFor(status.Severity);
        DetailQuota.Text = status.QuotaGB > 0
            ? $"/ {ByteFormat.GB(status.QuotaGB)}　（{ByteFormat.Percent(status.UsedFraction ?? 0)}）"
            : "／ 配额未知";

        DetailPeriod.Text =
            $"账期 {status.Period.StartDay} → {status.Period.EndDayExclusive}　剩 {status.RemainingDays} 天" +
            (status.RemainingGB is { } remaining ? $"　剩余流量 {ByteFormat.GB(remaining)}" : "");

        if (status.ProjectedGB is { } projected)
        {
            DetailProjection.Text = $"按当前速度预计月底用量 {ByteFormat.GB(projected)}"
                                    + (status.WillExceed ? "　⚠ 将超出配额" : "");
            DetailProjection.Foreground = status.WillExceed ? Theme.Critical : Theme.Normal;
            DetailProjection.Visibility = Visibility.Visible;
        }
        else
        {
            DetailProjection.Visibility = Visibility.Collapsed;
        }

        DetailMeter.Text =
            $"{status.Server.Provider.DisplayName()}　·　{status.Server.MeterMode.DisplayName()}　·　{status.Server.UnitBase.DisplayName()}";

        DetailLastSuccess.Text = status.LastSuccessAt is { } at
            ? $"上次成功采集：{ByteFormat.RelativeTime(at, DateTime.UtcNow)}"
            : "尚未成功采集过";

        DetailWarning.Text = string.Join("\n", status.Warnings);
        DetailWarning.Visibility = status.Warnings.Count > 0 ? Visibility.Visible : Visibility.Collapsed;

        DetailError.Text = status.LastError ?? "";
        DetailError.Visibility = string.IsNullOrEmpty(status.LastError)
            ? Visibility.Collapsed : Visibility.Visible;

        Chart.Update(status);
    }

    private void OnServerSelectionChanged(object sender, SelectionChangedEventArgs e) =>
        RenderDetail((ServerList.SelectedItem as ServerRowViewModel)?.Status);

    private async void OnRefreshClick(object sender, RoutedEventArgs e) =>
        await _state.RefreshAsync();

    private void OnSettingsClick(object sender, RoutedEventArgs e) => _state.ShowSettings(this);
}
