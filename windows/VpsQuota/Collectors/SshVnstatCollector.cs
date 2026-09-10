namespace VpsQuota.Collectors;

using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;
using VpsQuota.Core;
using VpsQuota.Models;

/// <summary>
/// 通过 SSH 在服务器上执行 vnstat 采集。
///
/// DMIT 没有公开 API，这是唯一可行的自动化途径；同时它也适用于任何没有 API 的服务商。
///
/// 刻意不引入 SSH 库，而是直接调用系统自带的 ssh.exe（Windows 10 1803+ 内置 OpenSSH 客户端）：
/// <list type="bullet">
/// <item>复用你已有的 ~/.ssh 配置、密钥、跳板机等，不必在本应用里重新配一遍</item>
/// <item>与 macOS 端调用 /usr/bin/ssh 的行为完全一致</item>
/// <item>不引入第三方依赖，也不需要在应用里处理私钥解密</item>
/// </list>
/// </summary>
public sealed class SshVnstatCollector : ICollector
{
    /// <summary>vnstat 日表默认保留 62 天（配置项 DayIsKept），一次取满即可覆盖任何账期。</summary>
    private const int DayLimit = 62;

    private readonly string _sshExecutable;
    private readonly TimeSpan _timeout;

    public SshVnstatCollector(string sshExecutable = "ssh.exe", TimeSpan? timeout = null)
    {
        _sshExecutable = sshExecutable;
        _timeout = timeout ?? TimeSpan.FromSeconds(45);
    }

    // vnstat 的 JSON 结构

    private sealed class VnstatOutput
    {
        [JsonPropertyName("interfaces")]
        public List<Interface> Interfaces { get; set; } = new();

        internal sealed class Interface
        {
            [JsonPropertyName("name")] public string Name { get; set; } = "";
            [JsonPropertyName("traffic")] public TrafficData Traffic { get; set; } = new();
        }

        internal sealed class TrafficData
        {
            [JsonPropertyName("day")] public List<DayEntry>? Day { get; set; }
        }

        internal sealed class DayEntry
        {
            [JsonPropertyName("date")] public DatePart Date { get; set; } = new();
            [JsonPropertyName("rx")] public long Rx { get; set; }
            [JsonPropertyName("tx")] public long Tx { get; set; }
        }

        internal sealed class DatePart
        {
            [JsonPropertyName("year")] public int Year { get; set; }
            [JsonPropertyName("month")] public int Month { get; set; }
            [JsonPropertyName("day")] public int Day { get; set; }
        }
    }

    public async Task<CollectResult> FetchAsync(
        ServerConfig server, DateTime since, CancellationToken ct = default)
    {
        var output = await RunRemoteAsync(server, RemoteCommand(server), ct).ConfigureAwait(false);

        // 远端命令的第一行是 `date +%z` 的输出（形如 +0000），其后才是 vnstat 的 JSON。
        var braceIndex = output.IndexOf('{');
        if (braceIndex < 0)
        {
            throw CollectException.NoData(
                $"服务器「{server.Name}」上的 vnstat 没有返回 JSON。原始输出：\n" +
                output[..Math.Min(output.Length, 500)]);
        }

        var offsetText = output[..braceIndex].Trim();
        var jsonText = output[braceIndex..];

        VnstatOutput parsed;
        try
        {
            parsed = JsonSerializer.Deserialize<VnstatOutput>(jsonText)
                     ?? throw CollectException.Decode("vnstat 返回内容为空");
        }
        catch (JsonException ex)
        {
            throw CollectException.Decode($"vnstat 输出解析失败：{ex.Message}");
        }

        // 指定了网卡就按名字挑，没指定就取第一个。
        var wanted = server.Interface?.Trim();
        var iface = !string.IsNullOrEmpty(wanted)
            ? parsed.Interfaces.FirstOrDefault(i => i.Name == wanted)
            : parsed.Interfaces.FirstOrDefault();

        if (iface is null)
        {
            var available = string.Join(", ", parsed.Interfaces.Select(i => i.Name));
            throw CollectException.NoData(
                $"服务器「{server.Name}」上没有找到网卡「{wanted}」。" +
                $"vnstat 正在统计的网卡有：{(available.Length == 0 ? "（无）" : available)}");
        }

        if (iface.Traffic.Day is not { Count: > 0 } dayEntries)
        {
            throw CollectException.NoData(
                $"网卡「{iface.Name}」还没有可用的日流量数据。" +
                "vnstat 刚安装时需要运行一段时间才会产生记录。");
        }

        var sinceDay = UtcDay.String(since);
        var days = dayEntries
            .Select(e => new DailyUsage(
                UtcDay.String(e.Date.Year, e.Date.Month, e.Date.Day), e.Rx, e.Tx))
            .Where(d => string.CompareOrdinal(d.Day, sinceDay) >= 0)
            .OrderBy(d => d.Day, StringComparer.Ordinal)
            .ToList();

        var warnings = new List<string>();
        // vnstat 按服务器本地时区切分自然日，本应用统一按 UTC 记账。
        // 时区不是 UTC 时，账期首尾两天会有几小时的归属偏差 —— 量不大，但要说清楚。
        if (offsetText.Length > 0 && offsetText != "+0000")
        {
            warnings.Add(
                $"服务器时区为 UTC{offsetText}，vnstat 的日切分与本应用的 UTC 记账存在数小时偏差。" +
                "如需完全对齐，可在服务器上执行 timedatectl set-timezone UTC。");
        }

        return new CollectResult { Days = days, Warnings = warnings };
    }

    /// <summary>列出服务器上 vnstat 正在统计的网卡，供设置界面的"测试连接"使用。</summary>
    public async Task<List<string>> ListInterfacesAsync(ServerConfig server, CancellationToken ct = default)
    {
        var output = await RunRemoteAsync(server, "vnstat --json d 1", ct).ConfigureAwait(false);
        var braceIndex = output.IndexOf('{');
        if (braceIndex < 0)
        {
            throw CollectException.NoData(
                "vnstat 没有返回 JSON。原始输出：\n" + output[..Math.Min(output.Length, 500)]);
        }

        var parsed = JsonSerializer.Deserialize<VnstatOutput>(output[braceIndex..]);
        return parsed?.Interfaces.Select(i => i.Name).ToList() ?? new List<string>();
    }

    private static string RemoteCommand(ServerConfig server)
    {
        var vnstat = "vnstat";
        var iface = server.Interface?.Trim();
        if (!string.IsNullOrEmpty(iface)) vnstat += $" -i {ShellQuote(iface)}";
        vnstat += $" --json d {DayLimit}";

        // 先输出时区偏移，再输出 JSON —— 一次往返同时拿到数据和校准信息。
        return $"date +%z; {vnstat}";
    }

    private async Task<string> RunRemoteAsync(ServerConfig server, string command, CancellationToken ct)
    {
        var host = server.SshHost?.Trim();
        if (string.IsNullOrEmpty(host))
            throw CollectException.Misconfigured($"服务器「{server.Name}」未填写 SSH 地址");

        // 以 '-' 开头的地址会被 ssh 当成选项解析（例如 -oProxyCommand=…），
        // 那等于让 config.json 决定本机执行什么命令。配置文件是明文、且鼓励在机器间拷贝，
        // 不能假定它可信，所以这里直接拒绝。
        if (host.StartsWith('-'))
            throw CollectException.Misconfigured(
                $"服务器「{server.Name}」的 SSH 地址不能以「-」开头：{host}");

        var args = new List<string>
        {
            // 禁止一切交互式提问：缺密钥、host key 变更等情况要立刻失败并报错，
            // 而不是让后台采集永远挂在一个没人看得见的提示上。
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "LogLevel=ERROR",
        };

        if (server.SshPort is > 0 and not 22)
        {
            args.Add("-p");
            args.Add(server.SshPort.Value.ToString());
        }

        var keyPath = server.SshKeyPath?.Trim();
        if (!string.IsNullOrEmpty(keyPath))
        {
            args.Add("-i");
            args.Add(ExpandHome(keyPath));
        }

        var user = server.SshUser?.Trim() ?? "";
        var target = string.IsNullOrEmpty(user) ? host : $"{user}@{host}";
        // "--" 终结选项解析，此后的参数一律当作目标和命令，双保险。
        args.Add("--");
        args.Add(target);
        args.Add(command);

        ProcessResult result;
        try
        {
            result = await ProcessRunner.RunAsync(_sshExecutable, args, _timeout, ct).ConfigureAwait(false);
        }
        catch (ProcessLaunchException ex)
        {
            throw new CollectException(
                $"{ex.Message}\n" +
                "Windows 10 1803 及以上版本自带 OpenSSH 客户端。若提示找不到 ssh.exe，" +
                "请在「设置 → 系统 → 可选功能」中安装「OpenSSH 客户端」。");
        }

        if (result.ExitCode != 0)
        {
            throw CollectException.CommandFailed(
                $"ssh {target} {command}",
                result.ExitCode,
                string.IsNullOrWhiteSpace(result.Stderr) ? result.Stdout : result.Stderr);
        }

        return result.Stdout;
    }

    /// <summary>把 ~ 展开成用户主目录，让两端的配置文件可以直接互换。</summary>
    private static string ExpandHome(string path)
    {
        if (!path.StartsWith('~')) return path;
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        return Path.Combine(home, path.TrimStart('~').TrimStart('/', '\\'));
    }

    /// <summary>单引号包裹并转义，防止网卡名里的特殊字符被远端 shell 解释。</summary>
    private static string ShellQuote(string value) =>
        "'" + value.Replace("'", "'\\''") + "'";
}
