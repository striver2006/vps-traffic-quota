namespace VpsQuota.Storage;

using System.IO;
using Microsoft.Win32;

/// <summary>
/// 开机自启：在 <c>HKCU\Software\Microsoft\Windows\CurrentVersion\Run</c> 下登记本程序。
///
/// 用注册表而不是往「启动」文件夹里放快捷方式：写注册表不需要额外的 COM 引用
/// （建快捷方式得走 IWshShortcut），改起来也是一次读写，不留下需要用户自己清理的文件。
/// 只写 HKCU，不碰 HKLM —— 后者要管理员权限，而这只是当前用户的偏好。
///
/// 状态源是注册表本身，不做本地缓存：用户随时可能用任务管理器的「启动」页把它禁掉。
/// </summary>
public static class LaunchAtLogin
{
    private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";

    /// <summary>注册表里的值名。改动它会让旧登记变成清不掉的孤儿项。</summary>
    private const string ValueName = "VpsQuota";

    /// <summary>
    /// 当前可执行文件的完整路径。
    ///
    /// 用 <see cref="Environment.ProcessPath"/> 而不是 Assembly.Location：
    /// 单文件发布时后者返回空字符串，那样写进注册表的会是一条打不开的路径。
    /// </summary>
    public static string? ExecutablePath
    {
        get
        {
            var path = Environment.ProcessPath;
            // dotnet run 时进程是 dotnet.exe，登记它没有意义（参数丢了，起不来本程序）。
            if (string.IsNullOrEmpty(path)) return null;
            return string.Equals(Path.GetFileName(path), "dotnet.exe",
                       StringComparison.OrdinalIgnoreCase)
                ? null
                : path;
        }
    }

    public static bool IsEnabled
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath);
            return key?.GetValue(ValueName) is string value && !string.IsNullOrWhiteSpace(value);
        }
    }

    /// <summary>
    /// 写入或删除登记。启用时总是重写一遍当前路径 ——
    /// 用户把 exe 挪了地方之后，旧登记指向的路径已经不存在了，得顺手自愈。
    /// </summary>
    public static void SetEnabled(bool enabled)
    {
        if (enabled)
        {
            var exe = ExecutablePath
                ?? throw new InvalidOperationException(
                    "无法确定程序路径，请直接运行 VpsQuota.exe 后再开启此选项。");

            using var key = Registry.CurrentUser.CreateSubKey(RunKeyPath)
                ?? throw new InvalidOperationException("无法写入注册表的启动项。");
            // 路径里可能有空格，不加引号会被拆成程序名 + 参数。
            key.SetValue(ValueName, $"\"{exe}\"", RegistryValueKind.String);
        }
        else
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: true);
            // 值不存在时 DeleteValue 会抛异常，显式说明"没有也算删干净了"。
            key?.DeleteValue(ValueName, throwOnMissingValue: false);
        }
    }
}
