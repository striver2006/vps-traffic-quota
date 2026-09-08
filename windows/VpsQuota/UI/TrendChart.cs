namespace VpsQuota.UI;

using System.Globalization;
using System.Windows;
using System.Windows.Media;
using VpsQuota.Core;
using VpsQuota.Models;

/// <summary>
/// 账期趋势图：每日用量柱状 + 累计折线 + 配额线。
///
/// 自绘而不引第三方图表库 —— 需要的只是三种图元，一个依赖不值得。
/// </summary>
public sealed class TrendChart : FrameworkElement
{
    private ServerStatus? _status;

    public void Update(ServerStatus? status)
    {
        _status = status;
        InvalidateVisual();
    }

    protected override void OnRender(DrawingContext dc)
    {
        var width = ActualWidth;
        var height = ActualHeight;
        if (width <= 0 || height <= 0) return;

        var background = new SolidColorBrush(Color.FromRgb(0xFA, 0xFA, 0xFA));
        dc.DrawRectangle(background, null, new Rect(0, 0, width, height));

        if (_status is null || _status.Days.Count == 0)
        {
            DrawCenteredText(dc, "本账期还没有数据", width, height);
            return;
        }

        var status = _status;
        var mode = status.Server.MeterMode;
        var bytesPerGB = status.Server.UnitBase.BytesPerGB();

        // 按天折算出「当日用量」和「账期累计」
        var daily = new double[status.Days.Count];
        var cumulative = new double[status.Days.Count];
        var running = 0.0;
        for (var i = 0; i < status.Days.Count; i++)
        {
            var d = status.Days[i];
            daily[i] = mode.BilledBytes(d.RxBytes, d.TxBytes) / bytesPerGB;
            running += daily[i];
            cumulative[i] = running;
        }

        const double padLeft = 46, padRight = 12, padTop = 14, padBottom = 22;
        var plotWidth = width - padLeft - padRight;
        var plotHeight = height - padTop - padBottom;
        if (plotWidth <= 0 || plotHeight <= 0) return;

        // 纵轴上限取「累计用量」和「配额」中较大者，这样配额线始终画得进来。
        var maxCumulative = cumulative[^1];
        var axisMax = Math.Max(maxCumulative, status.QuotaGB > 0 ? status.QuotaGB : 0);
        if (axisMax <= 0) axisMax = 1;
        axisMax *= 1.08;   // 顶部留白，折线不贴边

        var axisPen = new Pen(new SolidColorBrush(Color.FromRgb(0xDD, 0xDD, 0xDD)), 1);
        axisPen.Freeze();
        dc.DrawLine(axisPen, new Point(padLeft, padTop), new Point(padLeft, padTop + plotHeight));
        dc.DrawLine(axisPen,
            new Point(padLeft, padTop + plotHeight),
            new Point(padLeft + plotWidth, padTop + plotHeight));

        double YFor(double gb) => padTop + plotHeight - gb / axisMax * plotHeight;

        // 纵轴刻度
        for (var i = 0; i <= 4; i++)
        {
            var value = axisMax * i / 4;
            var y = YFor(value);
            if (i > 0)
            {
                var gridPen = new Pen(new SolidColorBrush(Color.FromArgb(0x30, 0xCC, 0xCC, 0xCC)), 1);
                gridPen.Freeze();
                dc.DrawLine(gridPen, new Point(padLeft, y), new Point(padLeft + plotWidth, y));
            }
            DrawText(dc, ByteFormat.GB(value), padLeft - 6, y - 7, 9, Brushes.Gray, rightAlign: true);
        }

        // 每日用量柱：与折线共用一套坐标，直接叠在同一张图上，省一次视线切换。
        var slotWidth = plotWidth / status.Days.Count;
        var barWidth = Math.Max(1, Math.Min(14, slotWidth * 0.6));
        var barBrush = new SolidColorBrush(Color.FromArgb(0x55,
            ((SolidColorBrush)Theme.BrushFor(status.Severity)).Color.R,
            ((SolidColorBrush)Theme.BrushFor(status.Severity)).Color.G,
            ((SolidColorBrush)Theme.BrushFor(status.Severity)).Color.B));
        barBrush.Freeze();

        for (var i = 0; i < daily.Length; i++)
        {
            var centerX = padLeft + slotWidth * (i + 0.5);
            var top = YFor(daily[i]);
            var barHeight = padTop + plotHeight - top;
            if (barHeight < 0.5) continue;
            dc.DrawRectangle(barBrush, null,
                new Rect(centerX - barWidth / 2, top, barWidth, barHeight));
        }

        // 累计折线
        var linePen = new Pen(Theme.BrushFor(status.Severity), 2);
        linePen.Freeze();
        var geometry = new StreamGeometry();
        using (var ctx = geometry.Open())
        {
            ctx.BeginFigure(
                new Point(padLeft + slotWidth * 0.5, YFor(cumulative[0])), false, false);
            for (var i = 1; i < cumulative.Length; i++)
            {
                ctx.LineTo(new Point(padLeft + slotWidth * (i + 0.5), YFor(cumulative[i])), true, false);
            }
        }
        geometry.Freeze();
        dc.DrawGeometry(null, linePen, geometry);

        // 配额线：累计折线一旦顶上去就说明用完了，比看数字直观。
        if (status.QuotaGB > 0)
        {
            var quotaPen = new Pen(new SolidColorBrush(Color.FromArgb(0xAA, 0xE0, 0x3B, 0x33)), 1)
            {
                DashStyle = new DashStyle(new double[] { 4, 3 }, 0),
            };
            quotaPen.Freeze();
            var y = YFor(status.QuotaGB);
            dc.DrawLine(quotaPen, new Point(padLeft, y), new Point(padLeft + plotWidth, y));
            DrawText(dc, $"配额 {ByteFormat.GB(status.QuotaGB)}", padLeft + 4, y - 13, 9,
                new SolidColorBrush(Color.FromRgb(0xE0, 0x3B, 0x33)));
        }

        // 横轴首尾日期
        DrawText(dc, status.Days[0].Day, padLeft, padTop + plotHeight + 4, 9, Brushes.Gray);
        if (status.Days.Count > 1)
        {
            DrawText(dc, status.Days[^1].Day, padLeft + plotWidth, padTop + plotHeight + 4, 9,
                Brushes.Gray, rightAlign: true);
        }
    }

    private void DrawCenteredText(DrawingContext dc, string text, double width, double height)
    {
        var formatted = Format(text, 12, Brushes.Gray);
        dc.DrawText(formatted, new Point((width - formatted.Width) / 2, (height - formatted.Height) / 2));
    }

    private void DrawText(
        DrawingContext dc, string text, double x, double y, double size, Brush brush,
        bool rightAlign = false)
    {
        var formatted = Format(text, size, brush);
        dc.DrawText(formatted, new Point(rightAlign ? x - formatted.Width : x, y));
    }

    private FormattedText Format(string text, double size, Brush brush) =>
        new(text,
            CultureInfo.CurrentCulture,
            FlowDirection.LeftToRight,
            new Typeface("Segoe UI"),
            size,
            brush,
            VisualTreeHelper.GetDpi(this).PixelsPerDip);
}
