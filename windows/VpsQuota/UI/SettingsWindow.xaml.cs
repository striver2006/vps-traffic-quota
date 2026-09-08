namespace VpsQuota.UI;

using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using VpsQuota.Models;
using VpsQuota.Storage;

/// <summary>设置窗口：Vultr 凭据、刷新周期、服务器增删改。</summary>
public partial class SettingsWindow : Window
{
    private readonly AppState _state;
    private ServerConfig? _current;

    /// <summary>
    /// 在下拉框回填期间抑制事件处理，否则 SelectionChanged 会把还没填好的值写回模型。
    /// </summary>
    private bool _loading;

    public SettingsWindow(AppState state)
    {
        InitializeComponent();
        _state = state;

        MeterBox.ItemsSource = Enum.GetValues<MeterMode>()
            .Select(m => new ChoiceItem<MeterMode>(m, m.DisplayName())).ToList();
        UnitBox.ItemsSource = Enum.GetValues<UnitBase>()
            .Select(u => new ChoiceItem<UnitBase>(u, u.DisplayName())).ToList();
        ResetDayBox.ItemsSource = Enumerable.Range(1, 31)
            .Select(d => new ChoiceItem<int>(d, $"{d} 号")).ToList();

        ApiKeyBox.Password = _state.VultrApiKey;
        ConfigPathText.Text = new ConfigStore().FilePath;

        SelectInterval(_state.Config.RefreshIntervalMinutes);
        ReloadServerList();
    }

    /// <summary>下拉项：一个值配一段中文说明。</summary>
    private sealed record ChoiceItem<T>(T Value, string Label)
    {
        public override string ToString() => Label;
    }

    private void SelectInterval(int minutes)
    {
        foreach (ComboBoxItem item in IntervalBox.Items)
        {
            if (item.Tag is string tag && int.TryParse(tag, out var value) && value == minutes)
            {
                IntervalBox.SelectedItem = item;
                return;
            }
        }
        IntervalBox.SelectedIndex = 1;   // 默认每小时
    }

    private int SelectedInterval() =>
        IntervalBox.SelectedItem is ComboBoxItem { Tag: string tag } && int.TryParse(tag, out var v)
            ? v : 60;

    private void ReloadServerList()
    {
        var selectedId = _current?.Id;
        ServerList.ItemsSource = _state.Config.Servers
            .Select(s => new ServerListItem(s))
            .ToList();

        ServerList.SelectedItem = ((List<ServerListItem>)ServerList.ItemsSource)
            .FirstOrDefault(i => i.Server.Id == selectedId);
    }

    private sealed record ServerListItem(ServerConfig Server)
    {
        public override string ToString() =>
            $"{(string.IsNullOrEmpty(Server.Name) ? "未命名" : Server.Name)}　·　{Server.Provider.DisplayName()}";
    }

    // MARK: 表单读写

    private void OnSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        // 切换到另一台之前，先把当前表单的编辑结果收回模型，否则改动会丢。
        CommitForm();
        _current = (ServerList.SelectedItem as ServerListItem)?.Server;
        LoadForm();
    }

    private void LoadForm()
    {
        if (_current is null)
        {
            ServerPanel.Visibility = Visibility.Collapsed;
            return;
        }

        _loading = true;
        ServerPanel.Visibility = Visibility.Visible;
        TestResult.Text = "";

        NameBox.Text = _current.Name;
        VultrPanel.Visibility = _current.Provider == ProviderKind.Vultr
            ? Visibility.Visible : Visibility.Collapsed;
        SshPanel.Visibility = _current.Provider == ProviderKind.Ssh
            ? Visibility.Visible : Visibility.Collapsed;

        InstanceIdBox.Text = _current.VultrInstanceId ?? "";
        HostBox.Text = _current.SshHost ?? "";
        PortBox.Text = (_current.SshPort ?? 22).ToString();
        UserBox.Text = _current.SshUser ?? "";
        KeyPathBox.Text = _current.SshKeyPath ?? "";
        InterfaceBox.Text = _current.Interface ?? "";
        QuotaBox.Text = _current.QuotaGB.ToString(CultureInfo.InvariantCulture);

        MeterBox.SelectedItem = ((List<ChoiceItem<MeterMode>>)MeterBox.ItemsSource)
            .First(i => i.Value == _current.MeterMode);
        UnitBox.SelectedItem = ((List<ChoiceItem<UnitBase>>)UnitBox.ItemsSource)
            .First(i => i.Value == _current.UnitBase);
        ResetDayBox.SelectedItem = ((List<ChoiceItem<int>>)ResetDayBox.ItemsSource)
            .First(i => i.Value == Math.Clamp(_current.ResetDay, 1, 31));

        _loading = false;
    }

    /// <summary>把表单里的值写回 <see cref="_current"/>。</summary>
    private void CommitForm()
    {
        if (_current is null || _loading) return;

        _current.Name = NameBox.Text.Trim();
        _current.VultrInstanceId = Nullify(InstanceIdBox.Text);
        _current.SshHost = Nullify(HostBox.Text);
        _current.SshPort = int.TryParse(PortBox.Text.Trim(), out var port) && port > 0 ? port : 22;
        _current.SshUser = Nullify(UserBox.Text);
        _current.SshKeyPath = Nullify(KeyPathBox.Text);
        _current.Interface = Nullify(InterfaceBox.Text);

        // 配额填了非数字就当作 0（= Vultr 自动取 API 值 / 其他服务商显示"配额未知"），
        // 总比把用户的输入静默改成上一次的值要诚实。
        _current.QuotaGB = double.TryParse(
            QuotaBox.Text.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out var quota)
            ? Math.Max(0, quota) : 0;

        if (MeterBox.SelectedItem is ChoiceItem<MeterMode> meter) _current.MeterMode = meter.Value;
        if (UnitBox.SelectedItem is ChoiceItem<UnitBase> unit) _current.UnitBase = unit.Value;
        if (ResetDayBox.SelectedItem is ChoiceItem<int> day) _current.ResetDay = day.Value;
    }

    private static string? Nullify(string value) =>
        string.IsNullOrWhiteSpace(value) ? null : value.Trim();

    // MARK: 命令

    private void OnAddVultrClick(object sender, RoutedEventArgs e) => AddServer(ProviderKind.Vultr);

    private void OnAddSshClick(object sender, RoutedEventArgs e) => AddServer(ProviderKind.Ssh);

    private void AddServer(ProviderKind provider)
    {
        CommitForm();

        var server = new ServerConfig
        {
            Id = $"{provider.ToString().ToLowerInvariant()}-{Guid.NewGuid().ToString("n")[..8]}",
            Name = provider == ProviderKind.Vultr ? "新的 Vultr 实例" : "新的服务器",
            Provider = provider,
            QuotaGB = provider == ProviderKind.Vultr ? 0 : 1000,
            MeterMode = provider == ProviderKind.Vultr ? MeterMode.Outbound : MeterMode.Sum,
            ResetDay = 1,
            SshPort = provider == ProviderKind.Ssh ? 22 : null,
            SshUser = provider == ProviderKind.Ssh ? "root" : null,
        };

        _state.Config.Servers.Add(server);
        _current = server;
        ReloadServerList();
        ServerList.SelectedItem = ((List<ServerListItem>)ServerList.ItemsSource)
            .First(i => i.Server.Id == server.Id);
    }

    private void OnRemoveClick(object sender, RoutedEventArgs e)
    {
        if (_current is null) return;

        var answer = MessageBox.Show(
            $"确定删除「{_current.Name}」吗？\n\n本地已采集的历史数据会保留，重新添加同名服务器不会自动恢复（历史按内部 ID 关联）。",
            "VPS 流量", MessageBoxButton.OKCancel, MessageBoxImage.Question);
        if (answer != MessageBoxResult.OK) return;

        _state.Config.Servers.RemoveAll(s => s.Id == _current.Id);
        _current = null;
        ReloadServerList();
        LoadForm();
    }

    private async void OnTestClick(object sender, RoutedEventArgs e)
    {
        if (_current is null) return;

        CommitForm();
        _state.VultrApiKey = ApiKeyBox.Password;
        _state.Config.RefreshIntervalMinutes = SelectedInterval();
        // 测试前先落盘，否则测的是编辑前的旧值。
        _state.SaveConfig();

        TestButton.IsEnabled = false;
        TestResult.Text = "测试中…";
        TestResult.Foreground = Theme.Unknown;

        var error = await _state.TestServerAsync(_current);

        TestButton.IsEnabled = true;
        if (error is null)
        {
            TestResult.Text = "✅ 连接成功，已采集到数据。";
            TestResult.Foreground = Theme.Normal;
        }
        else
        {
            TestResult.Text = "❌ " + error;
            TestResult.Foreground = Theme.Critical;
        }
    }

    private void OnSaveClick(object sender, RoutedEventArgs e)
    {
        CommitForm();
        _state.VultrApiKey = ApiKeyBox.Password;
        _state.Config.RefreshIntervalMinutes = SelectedInterval();
        _state.SaveConfig();
        Close();
    }
}
