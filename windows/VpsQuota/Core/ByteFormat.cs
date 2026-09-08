namespace VpsQuota.Core;

using System.Globalization;

/// <summary>面向展示的数值格式化。</summary>
public static class ByteFormat
{
    /// <summary>把 GB 数格式化成人读字符串：小于 1 GB 用 MB，大于等于 1024 GB 用 TB。</summary>
    public static string GB(double value)
    {
        var c = CultureInfo.InvariantCulture;
        if (value < 1) return string.Format(c, "{0:F0} MB", value * 1024);
        if (value >= 1024) return string.Format(c, "{0:F2} TB", value / 1024);
        return string.Format(c, value >= 100 ? "{0:F0} GB" : "{0:F1} GB", value);
    }

    public static string Percent(double fraction) =>
        string.Format(CultureInfo.InvariantCulture, "{0:F0}%", fraction * 100);

    /// <summary>相对时间，用于"上次刷新于 …"。</summary>
    public static string RelativeTime(DateTime utc, DateTime now)
    {
        var seconds = (int)(now - utc).TotalSeconds;
        if (seconds < 60) return "刚刚";
        if (seconds < 3600) return $"{seconds / 60} 分钟前";
        if (seconds < 86_400) return $"{seconds / 3600} 小时前";
        return $"{seconds / 86_400} 天前";
    }
}
