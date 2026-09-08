namespace VpsQuota.Storage;

using System.IO;

/// <summary>
/// 应用数据目录。
///
/// 与 macOS 端的 <c>~/Library/Application Support/VPSTrafficQuota/</c> 一一对应，
/// 文件名保持一致，方便在两台机器之间直接拷贝 config.json。
/// </summary>
public static class AppPaths
{
    public const string DirectoryName = "VPSTrafficQuota";

    public static string Directory => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        DirectoryName);

    public static string ConfigFile => Path.Combine(Directory, "config.json");
    public static string DatabaseFile => Path.Combine(Directory, "usage.sqlite");
    public static string SecretFile => Path.Combine(Directory, "secrets.bin");

    public static void EnsureDirectory() => System.IO.Directory.CreateDirectory(Directory);
}
