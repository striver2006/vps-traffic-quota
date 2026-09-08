namespace VpsQuota.Core;

using System.Globalization;

/// <summary>
/// UTC 自然日的字符串工具。
///
/// 全程用 <c>yyyy-MM-dd</c> 字符串而不是 DateTime 作为日粒度的键，有两个实际好处：
/// 1. 该格式的字典序等于时间序，SQLite 里 <c>WHERE day &gt;= ? AND day &lt; ?</c> 直接可用；
/// 2. 避开时区在存储层的反复转换 —— 转换只发生在采集边界上，一次性做完。
/// </summary>
public static class UtcDay
{
    public const string Format = "yyyy-MM-dd";

    public static string String(DateTime utc) =>
        utc.ToString(Format, CultureInfo.InvariantCulture);

    public static string String(int year, int month, int day) =>
        $"{year:D4}-{month:D2}-{day:D2}";

    /// <summary>解析 yyyy-MM-dd，返回该 UTC 日的零点。格式不合法时返回 null。</summary>
    public static DateTime? Parse(string value) =>
        DateTime.TryParseExact(
            value, Format, CultureInfo.InvariantCulture,
            DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal,
            out var parsed)
            ? DateTime.SpecifyKind(parsed.Date, DateTimeKind.Utc)
            : null;

    public static DateTime StartOfDay(DateTime utc) =>
        DateTime.SpecifyKind(utc.Date, DateTimeKind.Utc);
}
