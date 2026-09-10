namespace VpsQuota.Storage;

using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;
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

        // 不写出 null。Swift 的 JSONEncoder 会省略 nil，这里不省的话两端产物不是同一份文本；
        // 更要紧的是 C# 自己的 int/double/bool 属性是非 nullable 的，
        // 读到显式 null 会直接抛 JsonException —— 等于自己写出来的文件自己读不回去。
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,

        // 刻意不开 PropertyNameCaseInsensitive：macOS 端的 JSONDecoder 严格区分大小写，
        // 这边宽松的话，{"Provider": …} 这种文件在 Windows 上能过、拷到 macOS 才炸，
        // 问题暴露得比出错的地方晚得多。两端一样严格，填错当场就能发现。
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
        SkippedServerCount = 0;
        if (!Exists) return new AppConfig();

        var json = File.ReadAllText(_path);
        TolerantServerListConverter.TakeSkippedCount();   // 清掉上一次的残留
        var config = JsonSerializer.Deserialize<AppConfig>(json, Options) ?? new AppConfig();
        SkippedServerCount = TolerantServerListConverter.TakeSkippedCount();
        return config;
    }

    /// <summary>
    /// 上一次 <see cref="Load"/> 里被跳过的服务器条目数（缺 id/name/provider 或字段类型不对）。
    /// 界面据此提示「有 N 台没读进来」，而不是让用户自己发现少了机器。
    /// </summary>
    public int SkippedServerCount { get; private set; }

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
