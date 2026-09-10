namespace VpsQuota.Tests;

using VpsQuota.Core;
using Xunit;

/// <summary>
/// 展示层格式化。换挡位置必须与 macOS 端一致，否则同一份数据两端读数不同。
/// </summary>
public class ByteFormatTests
{
    [Theory(DisplayName = "GB 的换挡位置：<1 用 MB，>=1024 用 TB")]
    [InlineData(0.5, "512 MB")]
    [InlineData(1.0, "1.0 GB")]
    [InlineData(99.9, "99.9 GB")]
    [InlineData(100.0, "100 GB")]
    [InlineData(1023.0, "1023 GB")]
    [InlineData(1024.0, "1.00 TB")]
    [InlineData(2048.0, "2.00 TB")]
    public void GBSwitchesUnits(double value, string expected) =>
        Assert.Equal(expected, ByteFormat.GB(value));

    [Theory(DisplayName = "百分比保留整数位")]
    [InlineData(0.0, "0%")]
    [InlineData(0.7, "70%")]
    [InlineData(1.0, "100%")]
    [InlineData(1.234, "123%")]
    public void PercentIsWhole(double fraction, string expected) =>
        Assert.Equal(expected, ByteFormat.Percent(fraction));

    [Theory(DisplayName = "相对时间的分档")]
    [InlineData(30, "刚刚")]
    [InlineData(60, "1 分钟前")]
    [InlineData(3600, "1 小时前")]
    [InlineData(86_400, "1 天前")]
    public void RelativeTimeBuckets(int secondsAgo, string expected)
    {
        var now = new DateTime(2026, 9, 10, 12, 0, 0, DateTimeKind.Utc);
        Assert.Equal(expected, ByteFormat.RelativeTime(now.AddSeconds(-secondsAgo), now));
    }
}
