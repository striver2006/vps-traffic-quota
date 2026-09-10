namespace VpsQuota.UI;

using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using VpsQuota.Core;
using VpsQuota.Models;
using VpsQuota.Storage;

/// <summary>设置窗口：Vultr 凭据、刷新周期、服务器增删改。</summary>
public partial class SettingsWindow : Window
{
    private readonly AppState _state;

    /// <summary>
    /// 编辑中的配置草稿。窗口自始至终只改它，点「保存」才整体提交给 <see cref="AppState"/>。
    /// 直接改 <c>_state.Config</c> 的话，TrafficMonitor 拿的是同一个实例，
    /// 未保存的增删立刻就生效于正在运行的采集了。
    /// </summary>
    private readonly AppConfig _draft;

    private ServerConfig? _current;

    /// <summary>
    /// 在下拉框回填期间抑制事件处理，否则 SelectionChanged 会把还没填好的值写回模型。
    /// </summary>
    private bool _loading;

    public SettingsWindow(AppState state)
    {
        InitializeComponent();
        _state = state;
        _draft = state.Config.Clone();

        MeterBox.ItemsSource = Enum.GetValues<MeterMode>()
            .Select(m => new ChoiceItem<MeterMode>(m, m.DisplayName())).ToList();
        UnitBox.ItemsSource = Enum.GetValues<UnitBase>()
            .Select(u => new ChoiceItem<UnitBase>(u, u.DisplayName())).ToList();
        ResetDayBox.ItemsSource = Enumerable.Range(1, 31)
            .Select(d => new ChoiceItem<int>(d, $"{d} 号")).ToList();

        ApiKeyBox.Password = _state.VultrApiKey;
        ConfigPathText.Text = new ConfigStore().FilePath;

        SelectInterval(_draft.RefreshIntervalMinutes);
        ReloadServerList();
        ReloadMenuBarChoices();

        // 开机自启的真实状态在注册表里（用户随时可能在任务管理器里禁掉它），每次开窗都重读。
        // 只在这里读一次就够：窗口关掉后 AppState 会重建实例，构造函数即"每次打开"。
        // 不要挂到 Activated 上 —— 那样用户勾完切去别的窗口再切回来，勾选会被悄悄抹掉。
        ReloadLaunchAtLogin();
    }

    // MARK: 开机自启

    private void ReloadLaunchAtLogin()
    {
        LaunchAtLoginBox.IsChecked = LaunchAtLogin.IsEnabled;
        LaunchAtLoginError.Visibility = Visibility.Collapsed;
    }

    /// <summary>把勾选框写进注册表。返回 false 表示失败，错误已显示在界面上。</summary>
    private bool CommitLaunchAtLogin()
    {
        var wanted = LaunchAtLoginBox.IsChecked == true;
        try
        {
            LaunchAtLogin.SetEnabled(wanted);
            LaunchAtLoginError.Visibility = Visibility.Collapsed;
            return true;
        }
        catch (Exception ex)
        {
            // 光把勾选框弹回去，用户只会以为是自己点漏了，得说明原因。
            LaunchAtLoginError.Text = $"开机自启设置失败：{ex.Message}";
            LaunchAtLoginError.Visibility = Visibility.Visible;
            LaunchAtLoginBox.IsChecked = LaunchAtLogin.IsEnabled;
            OnShowGeneralClick(this, new RoutedEventArgs());
            return false;
        }
    }

    /// <summary>下拉项：一个值配一段中文说明。</summary>
    private sealed record ChoiceItem<T>(T Value, string Label)
    {
        public override string ToString() => Label;
    }

    /// <summary>
    /// 「托盘显示哪台」的下拉项。<paramref name="Shows"/> 为 false 是「不显示」；
    /// 为 true 且 <paramref name="Id"/> 为 null 则自动挑用量最紧张的那台。
    /// </summary>
    private sealed record MenuBarChoice(bool Shows, string? Id, string Label)
    {
        public override string ToString() => Label;
    }

    /// <summary>按当前的服务器列表重建「托盘显示哪台」的选项，保留原有选择。</summary>
    private void ReloadMenuBarChoices()
    {
        // 第一次填充时下拉里还什么都没有，选择只能从配置取；
        // 之后要以界面上的当前选择为准，否则用户改成「自动」再加一台会被弹回去。
        var current = MenuBarServerBox.SelectedItem as MenuBarChoice
            ?? new MenuBarChoice(_draft.MenuBarShowsRemaining,
                                 _draft.MenuBarServerId, "");

        var choices = new List<MenuBarChoice>
        {
            new(false, null, "不显示（只留图标）"),
            new(true, null, "自动（用量最紧张的一台）"),
        };
        choices.AddRange(_draft.Servers.Select(s =>
            new MenuBarChoice(true, s.Id, string.IsNullOrEmpty(s.Name) ? "未命名" : s.Name)));

        MenuBarServerBox.ItemsSource = choices;
        MenuBarServerBox.SelectedItem =
            choices.FirstOrDefault(c => c.Shows == current.Shows && c.Id == current.Id)
            ?? choices[1];   // 指定的那台没了就回到「自动」
    }

    /// <summary>把下拉里的选择写回配置。「不显示」保留原来指定的那台，改回来不用重选。</summary>
    private void CommitMenuBarChoice()
    {
        if (MenuBarServerBox.SelectedItem is not MenuBarChoice choice) return;

        _draft.MenuBarShowsRemaining = choice.Shows;
        if (choice.Shows) _draft.MenuBarServerId = choice.Id;
    }

    // MARK: 页面导航

    private void OnShowServersClick(object sender, RoutedEventArgs e)
    {
        ServersPage.Visibility = Visibility.Visible;
        GeneralPage.Visibility = Visibility.Collapsed;
        ServersNavButton.Style = (Style)FindResource("NavActiveButton");
        GeneralNavButton.Style = (Style)FindResource("NavButton");
    }

    private void OnShowGeneralClick(object sender, RoutedEventArgs e)
    {
        CommitForm();
        // 名称可能刚在服务器页改过，切过来之前把下拉里的标签同步一遍。
        ReloadMenuBarChoices();
        ServersPage.Visibility = Visibility.Collapsed;
        GeneralPage.Visibility = Visibility.Visible;
        ServersNavButton.Style = (Style)FindResource("NavButton");
        GeneralNavButton.Style = (Style)FindResource("NavActiveButton");
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

        // 重设 ItemsSource 会让 ListBox 丢掉选中项并触发一次 SelectionChanged，
        // 那条路径上的 CommitForm() 会把「表单里还留着的上一台的文本」写进当前的 _current。
        // 新增服务器时 _current 已经指向新建那台，于是新机器的字段被上一台整个覆盖。
        // 这里用 _loading 把这段过渡期屏蔽掉（CommitForm 已有 _loading 早退条件）。
        var wasLoading = _loading;
        _loading = true;
        try
        {
            ServerList.ItemsSource = _draft.Servers
                .Select(s => new ServerListItem(s))
                .ToList();

            ServerList.SelectedItem = ((List<ServerListItem>)ServerList.ItemsSource)
                .FirstOrDefault(i => i.Server.Id == selectedId);
        }
        finally { _loading = wasLoading; }
    }

    private sealed record ServerListItem(ServerConfig Server)
    {
        public string Name => string.IsNullOrEmpty(Server.Name) ? "未命名" : Server.Name;
        public string ProviderName => Server.Provider.DisplayName();
        public override string ToString() => $"{Name}　·　{ProviderName}";
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
            EmptyServerPanel.Visibility = Visibility.Visible;
            return;
        }

        _loading = true;
        ServerPanel.Visibility = Visibility.Visible;
        EmptyServerPanel.Visibility = Visibility.Collapsed;
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

        // 基准绑定到具体账期：只有当前账期与记录的一致时才回填，否则视为已失效。
        var periodStart = CurrentPeriodStart(_current);
        BaselineBox.Text = _current.UsageBaseline is { } b && b.PeriodStart == periodStart
            ? b.UsedGB.ToString(CultureInfo.InvariantCulture)
            : "0";
        BaselinePeriodText.Text =
            $"只对 {periodStart} 起的这个账期有效，下个账期开始后自动清零 —— 否则它会变成凭空多出来的流量。";

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

        // ResetDay 必须先写回：下面算账期戳要用它。放在后面的话，用户在同一次编辑里
        // 既改重置日又填起始已用量时，基准会被绑到「旧重置日」算出的账期起始日，
        // AppliesTo 恒为 false，补偿静默失效 —— 用户只会觉得数字对不上面板。
        if (MeterBox.SelectedItem is ChoiceItem<MeterMode> meter) _current.MeterMode = meter.Value;
        if (UnitBox.SelectedItem is ChoiceItem<UnitBase> unit) _current.UnitBase = unit.Value;
        if (ResetDayBox.SelectedItem is ChoiceItem<int> day) _current.ResetDay = day.Value;

        var baselineGB = double.TryParse(
            BaselineBox.Text.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out var bl)
            ? Math.Max(0, bl) : 0;
        _current.UsageBaseline = baselineGB > 0
            ? new UsageBaseline { PeriodStart = CurrentPeriodStart(_current), UsedGB = baselineGB }
            : null;
    }

    /// <summary>该服务器当前账期的起始日，用于把基准绑定到具体账期。</summary>
    private static string CurrentPeriodStart(ServerConfig server) =>
        BillingPeriod.Current(server.ResetDay, DateTime.UtcNow).StartDay;

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

        _draft.Servers.Add(server);
        _current = server;
        ReloadServerList();
        ReloadMenuBarChoices();
        ServerList.SelectedItem = ((List<ServerListItem>)ServerList.ItemsSource)
            .First(i => i.Server.Id == server.Id);
        // 显式把新对象的默认值填进表单，不依赖 SelectionChanged 的时序：
        // 上面那次赋值通常选中的就是 ReloadServerList 里已经选好的同一个实例，
        // WPF 判等后不会再发事件，表单也就不会被刷新。
        LoadForm();
    }

    private void OnRemoveClick(object sender, RoutedEventArgs e)
    {
        if (_current is null) return;

        var answer = MessageBox.Show(
            $"确定删除「{_current.Name}」吗？\n\n本地已采集的历史数据会保留，重新添加同名服务器不会自动恢复（历史按内部 ID 关联）。",
            "VPS 流量", MessageBoxButton.OKCancel, MessageBoxImage.Question);
        if (answer != MessageBoxResult.OK) return;

        _draft.Servers.RemoveAll(s => s.Id == _current.Id);
        // 删掉的正好是托盘在显示的那台时把指向清掉，
        // 否则配置里会留下一个悬空 ID，看不出托盘为什么换了一台。
        if (_draft.MenuBarServerId == _current.Id) _draft.MenuBarServerId = null;
        _current = null;
        ReloadServerList();
        ReloadMenuBarChoices();
        LoadForm();
    }

    private async void OnTestClick(object sender, RoutedEventArgs e)
    {
        if (_current is null) return;

        // 只把表单收回草稿即可 —— 测的就是草稿里这台的当前值。
        // 刻意不落盘：「测试连接」不该顺手把整份编辑提交掉。
        CommitForm();

        TestButton.IsEnabled = false;
        TestResult.Text = "测试中…";
        TestResult.Foreground = Theme.Unknown;

        var error = await _state.TestServerAsync(_current, ApiKeyBox.Password);

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
        _draft.RefreshIntervalMinutes = SelectedInterval();
        CommitMenuBarChoice();
        // 传副本：直接给 _draft 的话，保存后草稿与 _state.Config 就是同一个对象了 ——
        // 登记开机自启失败时窗口不关，之后的编辑会又直接改到正在生效的配置上。
        _state.ApplyConfig(_draft.Clone(), ApiKeyBox.Password);
        // 登记失败时不关窗，否则那条错误提示刚显示出来就随窗口一起消失了。
        if (!CommitLaunchAtLogin()) return;
        Close();
    }
}
