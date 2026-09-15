namespace VpsQuota.Core;

using System;
using System.Reflection;

/// <summary>
/// 统一管理应用版本与项目元信息，对应 macOS 端的 AppInfo。
/// </summary>
public static class AppInfo
{
    /// <summary>默认或编译回退版本号。</summary>
    public const string FallbackVersion = "1.0.1";

    /// <summary>项目仓库主页。</summary>
    public static readonly Uri ProjectUrl = new("https://github.com/striver2006/vps-traffic-quota");

    /// <summary>Releases 发布页面（用于检查与比对最新版本）。</summary>
    public static readonly Uri ReleasesUrl = new("https://github.com/striver2006/vps-traffic-quota/releases");

    /// <summary>
    /// 运行时版本号。优先从程序集 InformationalVersion 或 Version 读取，读取不到时回退到 FallbackVersion。
    /// </summary>
    public static string Version
    {
        get
        {
            var asm = Assembly.GetEntryAssembly() ?? typeof(AppInfo).Assembly;
            var infoVer = asm.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion;
            if (!string.IsNullOrWhiteSpace(infoVer))
            {
                return infoVer.Split('+')[0];
            }
            var ver = asm.GetName().Version;
            return ver is not null ? $"{ver.Major}.{ver.Minor}.{ver.Build}" : FallbackVersion;
        }
    }
}
