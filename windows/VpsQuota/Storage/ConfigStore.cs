namespace VpsQuota.Storage;

using System.IO;
using System.Text.Json;
using VpsQuota.Models;

/// <summary>读写 <c>%APPDATA%\VPSTrafficQuota\config.json</c>。</summary>
public sealed class ConfigStore
{
    private readonly string _path;

    private static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true,
        // 与 macOS 端的驼峰字段名保持一致，两端的 config.json 可以互换。
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
    };

    public ConfigStore(string? path = null) => _path = path ?? AppPaths.ConfigFile;

    public string FilePath => _path;

    public bool Exists => File.Exists(_path);

    /// <summary>
    /// 读取配置。文件不存在时返回空配置而不是报错 ——
    /// 首次启动就是这种情况，应用要能正常起来并引导用户去设置界面。
    /// </summary>
    public AppConfig Load()
    {
        if (!Exists) return new AppConfig();
        var json = File.ReadAllText(_path);
        return JsonSerializer.Deserialize<AppConfig>(json, Options) ?? new AppConfig();
    }

    public void Save(AppConfig config)
    {
        AppPaths.EnsureDirectory();
        var json = JsonSerializer.Serialize(config, Options);

        // 原子写入：先写临时文件再替换，避免写到一半崩溃留下半份配置。
        var temp = _path + ".tmp";
        File.WriteAllText(temp, json);
        File.Move(temp, _path, overwrite: true);
    }
}
