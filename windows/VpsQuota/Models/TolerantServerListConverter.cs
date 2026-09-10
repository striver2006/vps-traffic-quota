namespace VpsQuota.Models;

// 这些命名空间必须显式 using：XamlPreCompile 生成的 wpftmp 项目不继承 ImplicitUsings，
// 见 csproj 里的说明。
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

/// <summary>
/// 逐条解析 <c>servers</c> 数组的转换器。
/// </summary>
/// <remarks>
/// 存在的理由是两端的解析口径必须对称（G2、验收标准第 2 条）：
///
/// <list type="bullet">
/// <item>坏掉的一条**跳过并计数**，而不是让整份配置连同其他正常的服务器一起读不出来。
///       macOS 端做了同样的处理（见 <c>AppConfig.init(from:)</c> 里的 FailableServer）。</item>
/// <item>显式 <c>null</c> 的成员当作"没填"。C# 的 <c>int</c>/<c>double</c>/<c>bool</c> 是非
///       nullable 的，直接解析会抛 JsonException；而 Swift 侧走的是 decodeIfPresent，
///       显式 null 会退回默认值。不抹平的话，一份带 null 的文件在 macOS 上能读、
///       在 Windows 上整份失败。</item>
/// </list>
///
/// 必填字段与 macOS 端保持一致：<c>id</c>、<c>name</c>、<c>provider</c> 缺一不可。
/// 不在这里给它们默认值，否则漏填 provider 的配置会被静默当成 ssh 跑起来。
/// </remarks>
internal sealed class TolerantServerListConverter : JsonConverter<List<ServerConfig>>
{
    private static readonly string[] RequiredKeys = new[] { "id", "name", "provider" };

    /// <summary>上一次解析里被跳过的条目数。读取即清零。</summary>
    [ThreadStatic]
    private static int _skipped;

    public static int TakeSkippedCount()
    {
        var count = _skipped;
        _skipped = 0;
        return count;
    }

    public override List<ServerConfig> Read(
        ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        var result = new List<ServerConfig>();
        if (reader.TokenType == JsonTokenType.Null) return result;

        using var document = JsonDocument.ParseValue(ref reader);
        if (document.RootElement.ValueKind != JsonValueKind.Array) return result;

        foreach (var element in document.RootElement.EnumerateArray())
        {
            var server = TryReadServer(element, options);
            if (server is null) _skipped++;
            else result.Add(server);
        }

        return result;
    }

    private static ServerConfig? TryReadServer(JsonElement element, JsonSerializerOptions options)
    {
        if (element.ValueKind != JsonValueKind.Object) return null;

        foreach (var key in RequiredKeys)
        {
            if (!element.TryGetProperty(key, out var value) || value.ValueKind == JsonValueKind.Null)
            {
                return null;
            }
        }

        try
        {
            return JsonSerializer.Deserialize<ServerConfig>(WithoutNulls(element), options);
        }
        catch (JsonException)
        {
            // 类型对不上（比如 resetDay 写成了字符串）。丢这一条，别牵连其他台。
            return null;
        }
    }

    /// <summary>去掉值为 null 的成员，让"显式 null"与"没写这个键"等价。</summary>
    private static string WithoutNulls(JsonElement element)
    {
        using var buffer = new MemoryStream();
        using (var writer = new Utf8JsonWriter(buffer))
        {
            writer.WriteStartObject();
            foreach (var property in element.EnumerateObject())
            {
                if (property.Value.ValueKind == JsonValueKind.Null) continue;
                property.WriteTo(writer);
            }
            writer.WriteEndObject();
        }
        return Encoding.UTF8.GetString(buffer.ToArray());
    }

    public override void Write(
        Utf8JsonWriter writer, List<ServerConfig> value, JsonSerializerOptions options)
    {
        // 手写数组而不是 Serialize(writer, value, options)，避免再次进到本转换器。
        writer.WriteStartArray();
        foreach (var server in value) JsonSerializer.Serialize(writer, server, options);
        writer.WriteEndArray();
    }
}
