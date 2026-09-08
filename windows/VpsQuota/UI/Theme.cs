namespace VpsQuota.UI;

using System.Windows.Media;
using VpsQuota.Models;

/// <summary>配色。与 macOS 端的绿 / 橙 / 红三档一一对应。</summary>
public static class Theme
{
    public static readonly Brush Normal = Freeze(Color.FromRgb(0x34, 0xA8, 0x53));
    public static readonly Brush Warning = Freeze(Color.FromRgb(0xF2, 0x8B, 0x21));
    public static readonly Brush Critical = Freeze(Color.FromRgb(0xE0, 0x3B, 0x33));
    public static readonly Brush Unknown = Freeze(Color.FromRgb(0x99, 0x99, 0x99));

    public static Brush BrushFor(Severity severity) => severity switch
    {
        Severity.Normal => Normal,
        Severity.Warning => Warning,
        Severity.Critical => Critical,
        _ => Unknown,
    };

    public static System.Drawing.Color DrawingColorFor(Severity severity) => severity switch
    {
        Severity.Normal => System.Drawing.Color.FromArgb(0x34, 0xA8, 0x53),
        Severity.Warning => System.Drawing.Color.FromArgb(0xF2, 0x8B, 0x21),
        Severity.Critical => System.Drawing.Color.FromArgb(0xE0, 0x3B, 0x33),
        _ => System.Drawing.Color.FromArgb(0x99, 0x99, 0x99),
    };

    private static Brush Freeze(Color color)
    {
        var brush = new SolidColorBrush(color);
        brush.Freeze();   // 冻结后可跨线程使用，也省掉重复的变更通知开销
        return brush;
    }
}
