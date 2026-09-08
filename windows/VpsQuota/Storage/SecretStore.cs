namespace VpsQuota.Storage;

using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

/// <summary>
/// Vultr API Key 的存放处。
///
/// 密钥不进 config.json —— 配置文件是明文且用户可能会拷贝/备份它。
/// 用 DPAPI 以当前用户身份加密，对应 macOS 端的钥匙串实现：
/// 密文只能由同一台机器上的同一个 Windows 用户解开。
/// </summary>
public static class SecretStore
{
    private const string VultrKeyName = "vultrApiKey";

    /// <summary>额外的熵，让密文不能被同一用户下的其他程序顺手解开。</summary>
    private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("io.vpsquota.VPSTrafficQuota");

    public static string? GetVultrApiKey() => Read().GetValueOrDefault(VultrKeyName);

    public static void SetVultrApiKey(string? key)
    {
        var all = Read();
        if (string.IsNullOrEmpty(key)) all.Remove(VultrKeyName);
        else all[VultrKeyName] = key;
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
        File.WriteAllBytes(AppPaths.SecretFile, encrypted);
    }
}
