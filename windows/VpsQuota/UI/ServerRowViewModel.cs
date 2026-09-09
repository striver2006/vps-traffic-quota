namespace VpsQuota.UI;

using System.Windows;
using System.Windows.Media;
using VpsQuota.Core;
using VpsQuota.Models;

/// <summary>
/// 把 <see cref="ServerStatus"/> 转成界面可直接绑定的显示属性。
///
/// 刻意在这里把所有格式化和配色算完，XAML 里只做纯绑定 ——
/// 转换器和多重绑定的错误是运行时静默失败的，很难排查。
/// </summary>
public sealed class ServerRowViewModel
{
    public ServerStatus Status { get; }

    public ServerRowViewModel(ServerStatus status) => Status = status;

    public string Id => Status.Server.Id;
    public string Name => string.IsNullOrEmpty(Status.Server.Name) ? "未命名" : Status.Server.Name;
    public string ProviderText => Status.Server.Provider.DisplayName();

    public string PercentText =>
        Status.UsedFraction is { } f ? ByteFormat.Percent(f) : "";

    /// <summary>本账期还剩多少可用。配额未知时无从算起。</summary>
    public string RemainingText =>
        Status.RemainingGB is { } r ? $"剩余 {ByteFormat.GB(r)}" : "配额未知";

    /// <summary>这一台就是托盘图标当前反映的那台。</summary>
    public bool IsPinnedToTray { get; init; }

    public Visibility PinnedVisibility =>
        IsPinnedToTray ? Visibility.Visible : Visibility.Collapsed;

    public string UsageText
    {
        get
        {
            var quota = Status.QuotaGB > 0 ? ByteFormat.GB(Status.QuotaGB) : "配额未知";
            return $"{ByteFormat.GB(Status.UsedGB)} / {quota}";
        }
    }

    public string PeriodText =>
        $"{Status.Period.StartDay} → {Status.Period.EndDayExclusive}　剩 {Status.RemainingDays} 天";

    public string ProjectionText =>
        Status.ProjectedGB is { } p
            ? $"按当前速度预计月底 {ByteFormat.GB(p)}" + (Status.WillExceed ? "　⚠ 将超额" : "")
            : "";

    public bool HasProjection => Status.ProjectedGB is not null;

    public string LastSuccessText =>
        Status.LastSuccessAt is { } at
            ? $"上次成功采集：{ByteFormat.RelativeTime(at, DateTime.UtcNow)}"
            : "尚未成功采集过";

    public string? ErrorText => Status.LastError;

    public string WarningText => string.Join("\n", Status.Warnings);

    /// <summary>
    /// 直接给出 Visibility 而不是 bool：WPF 没有内置的 bool→Visibility 转换器，
    /// 自己写一个再挂进资源字典只会多一处可能拼错的字符串键。
    /// </summary>
    public Visibility ErrorVisibility =>
        string.IsNullOrEmpty(Status.LastError) ? Visibility.Collapsed : Visibility.Visible;

    public Visibility WarningVisibility =>
        Status.Warnings.Count > 0 ? Visibility.Visible : Visibility.Collapsed;

    /// <summary>进度条填充比例（0…1），配额未知时为 0。</summary>
    public double Fraction => Math.Clamp(Status.UsedFraction ?? 0, 0, 1);

    public Brush AccentBrush => Theme.BrushFor(Status.Severity);
}
