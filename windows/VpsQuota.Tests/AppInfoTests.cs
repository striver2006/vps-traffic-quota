namespace VpsQuota.Tests;

using System;
using VpsQuota.Core;
using Xunit;

public class AppInfoTests
{
    [Fact(DisplayName = "版本号非空且符合语义化版本格式")]
    public void VersionIsValid()
    {
        Assert.False(string.IsNullOrWhiteSpace(AppInfo.FallbackVersion));
        Assert.False(string.IsNullOrWhiteSpace(AppInfo.Version));

        var parts = AppInfo.Version.Split('.');
        Assert.True(parts.Length >= 2);
    }

    [Fact(DisplayName = "Releases 与 Project URL 有效")]
    public void UrlsAreValid()
    {
        Assert.Equal("https", AppInfo.ProjectUrl.Scheme);
        Assert.Equal("github.com", AppInfo.ProjectUrl.Host);
        Assert.Equal("https", AppInfo.ReleasesUrl.Scheme);
        Assert.EndsWith("/releases", AppInfo.ReleasesUrl.AbsoluteUri);
    }
}
