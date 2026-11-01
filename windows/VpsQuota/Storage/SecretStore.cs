namespace VpsQuota.Storage;

using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

/// <summary>
/// 各服务商 API Key 的存放处。
///
/// 密钥不进 config.json —— 配置文件是明文且用户可能会拷贝/备份它。
/// 用 DPAPI 以当前用户身份加密，对应 macOS 端的钥匙串实现：
/// 密文只能由同一台机器上的同一个 Windows 用户解开。
/// </summary>
public static class SecretStore
{
    private const string VultrKeyName = "vultrApiKey";

    /// <summary>搬瓦工的 Key 按 VEID（即按服务器）发，条目名带这个前缀。</summary>
    private const string BwgKeyPrefix = "bwg:";

    /// <summary>Hetzner 全局 API Token。</summary>
    private const string HetznerTokenName = "hetznerApiToken";

    /// <summary>Hetzner 按服务器配置的独立 Token 前缀。</summary>
    private const string HetznerKeyPrefix = "hetzner:";

    /// <summary>RackNerd API Key 前缀。</summary>
    private const string RackNerdKeyPrefix = "rn_key:";

    /// <summary>RackNerd API Hash 前缀。</summary>
    private const string RackNerdHashPrefix = "rn_hash:";

    /// <summary>额外的熵，让密文不能被同一用户下的其他程序顺手解开。</summary>
    private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("io.vpsquota.VPSTrafficQuota");

    public sealed record RackNerdSecret(string Key, string Hash);

    public static string? GetVultrApiKey() => Read().GetValueOrDefault(VultrKeyName);

    public static void SetVultrApiKey(string? key)
    {
        var all = Read();
        if (string.IsNullOrEmpty(key)) all.Remove(VultrKeyName);
        else all[VultrKeyName] = key;
        Write(all);
    }

    /// <summary>serverId → KiwiVM API Key。空字典表示一台都没配。</summary>
    public static Dictionary<string, string> GetBwgApiKeys() => Read()
        .Where(kv => kv.Key.StartsWith(BwgKeyPrefix, StringComparison.Ordinal))
        .ToDictionary(kv => kv.Key[BwgKeyPrefix.Length..], kv => kv.Value);

    /// <summary>整体重写搬瓦工的 Key：先清掉全部旧条目再写入新值，已删除服务器的残留随之消失。</summary>
    public static void SetBwgApiKeys(IReadOnlyDictionary<string, string>? keys)
    {
        var all = Read();
        foreach (var stale in all.Keys.Where(k => k.StartsWith(BwgKeyPrefix, StringComparison.Ordinal)).ToList())
        {
            all.Remove(stale);
        }
        if (keys is not null)
        {
            foreach (var (serverId, key) in keys)
            {
                if (!string.IsNullOrEmpty(key)) all[BwgKeyPrefix + serverId] = key;
            }
        }
        Write(all);
    }

    public static string? GetHetznerApiToken() => Read().GetValueOrDefault(HetznerTokenName);

    public static void SetHetznerApiToken(string? token)
    {
        var all = Read();
        if (string.IsNullOrEmpty(token)) all.Remove(HetznerTokenName);
        else all[HetznerTokenName] = token;
        Write(all);
    }

    /// <summary>serverId → Hetzner 独立 Token。</summary>
    public static Dictionary<string, string> GetHetznerServerTokens() => Read()
        .Where(kv => kv.Key.StartsWith(HetznerKeyPrefix, StringComparison.Ordinal))
        .ToDictionary(kv => kv.Key[HetznerKeyPrefix.Length..], kv => kv.Value);

    public static void SetHetznerServerTokens(IReadOnlyDictionary<string, string>? tokens)
    {
        var all = Read();
        foreach (var stale in all.Keys.Where(k => k.StartsWith(HetznerKeyPrefix, StringComparison.Ordinal)).ToList())
        {
            all.Remove(stale);
        }
        if (tokens is not null)
        {
            foreach (var (serverId, token) in tokens)
            {
                if (!string.IsNullOrEmpty(token)) all[HetznerKeyPrefix + serverId] = token;
            }
        }
        Write(all);
    }

    /// <summary>serverId → RackNerdSecret (Key & Hash)。</summary>
    public static Dictionary<string, RackNerdSecret> GetRackNerdSecrets()
    {
        var all = Read();
        var result = new Dictionary<string, RackNerdSecret>();
        foreach (var (k, v) in all)
        {
            if (k.StartsWith(RackNerdKeyPrefix, StringComparison.Ordinal))
            {
                var serverId = k[RackNerdKeyPrefix.Length..];
                var hash = all.GetValueOrDefault(RackNerdHashPrefix + serverId) ?? "";
                if (!string.IsNullOrEmpty(v) && !string.IsNullOrEmpty(hash))
                {
                    result[serverId] = new RackNerdSecret(v, hash);
                }
            }
        }
        return result;
    }

    public static void SetRackNerdSecrets(IReadOnlyDictionary<string, RackNerdSecret>? secrets)
    {
        var all = Read();
        foreach (var stale in all.Keys.Where(k => k.StartsWith(RackNerdKeyPrefix, StringComparison.Ordinal) || k.StartsWith(RackNerdHashPrefix, StringComparison.Ordinal)).ToList())
        {
            all.Remove(stale);
        }
        if (secrets is not null)
        {
            foreach (var (serverId, secret) in secrets)
            {
                if (!string.IsNullOrEmpty(secret.Key) && !string.IsNullOrEmpty(secret.Hash))
                {
                    all[RackNerdKeyPrefix + serverId] = secret.Key;
                    all[RackNerdHashPrefix + serverId] = secret.Hash;
                }
            }
        }
        Write(all);
    }

    private static Dictionary<string, string> Read()
    {
        var path = AppPaths.SecretFile;
        if (!File.Exists(path)) return new Dictionary<string, string>();

        try
        {
            var encrypted = File.ReadAllBytes(path);
            var plain = ProtectedData.Unprotect(encrypted, Entropy, DataProtectionScope.CurrentUser);
            return JsonSerializer.Deserialize<Dictionary<string, string>>(plain)
                   ?? new Dictionary<string, string>();
        }
        catch (Exception ex) when (ex is CryptographicException or JsonException)
        {
            // 换过机器或换过 Windows 账户就解不开了。此时当作"还没设置"处理，
            // 让用户重新填一次，而不是让整个应用起不来。
            return new Dictionary<string, string>();
        }
    }

    private static void Write(Dictionary<string, string> values)
    {
        AppPaths.EnsureDirectory();
        var plain = JsonSerializer.SerializeToUtf8Bytes(values);
        var encrypted = ProtectedData.Protect(plain, Entropy, DataProtectionScope.CurrentUser);

        // 原子写入：先写临时文件再替换，与 ConfigStore.Save 保持一致。
        // 直接覆写的话，写到一半崩溃会留下半个密文文件，下次 Unprotect 抛
        // CryptographicException，被 Read() 当成「还没设置」—— API Key 就这么静默没了，
        // 用户只会看到 Vultr 返回 401，完全猜不到原因。
        var path = AppPaths.SecretFile;
        var temp = path + ".tmp";
        File.WriteAllBytes(temp, encrypted);
        File.Move(temp, path, overwrite: true);
    }
}
