namespace VpsQuota.Tests;

using System.IO;
using System.Runtime.CompilerServices;
using System.Text.RegularExpressions;
using Microsoft.Data.Sqlite;
using VpsQuota.Storage;
using Xunit;

/// <summary>
/// <c>shared/schema.sql</c> 声称是两端建表语句的唯一事实源，但三份拷贝靠人工同步迟早会漂移。
/// </summary>
/// <remarks>
/// macOS 端有同名的一组测试，但它只验证 Swift 那一份拷贝 —— 一行 C# 都不碰。
/// 换句话说，此前没有任何机制阻止 <see cref="SqliteStore"/> 里那段 SQL 独自漂移。
/// 这组测试建一个真库，把它<b>实际</b>的表结构与 schema.sql 声明的对照。
/// </remarks>
public class SchemaConsistencyTests
{
    private static string RepoRoot([CallerFilePath] string? thisFile = null)
    {
        // windows/VpsQuota.Tests/SchemaConsistencyTests.cs → 上溯三级即仓库根
        var directory = Path.GetDirectoryName(thisFile)!;
        return Path.GetFullPath(Path.Combine(directory, "..", ".."));
    }

    /// <summary>从 schema.sql 解析出「表名 → [(列名, 类型)]」，忽略注释与空白差异。</summary>
    private static Dictionary<string, List<(string Name, string Type)>> DeclaredTables()
    {
        var sql = File.ReadAllText(Path.Combine(RepoRoot(), "shared", "schema.sql"));

        // 去掉 -- 行注释，它们只影响可读性，不影响结构
        sql = string.Join("\n", sql.Split('\n').Select(line =>
        {
            var index = line.IndexOf("--", StringComparison.Ordinal);
            return index < 0 ? line : line[..index];
        }));

        var result = new Dictionary<string, List<(string, string)>>();
        var matches = Regex.Matches(
            sql, @"CREATE TABLE IF NOT EXISTS\s+(\w+)\s*\(([^;]*)\)\s*;", RegexOptions.Singleline);

        foreach (Match match in matches)
        {
            var columns = new List<(string, string)>();
            foreach (var part in match.Groups[2].Value.Split(','))
            {
                var tokens = part.Split(
                    new[] { ' ', '\n', '\t', '\r' }, StringSplitOptions.RemoveEmptyEntries);
                // 跳过 PRIMARY KEY(...) 这类表级约束
                if (tokens.Length < 2 || tokens[0].Equals("PRIMARY", StringComparison.OrdinalIgnoreCase))
                    continue;
                columns.Add((tokens[0], tokens[1].ToUpperInvariant()));
            }
            result[match.Groups[1].Value] = columns;
        }

        return result;
    }

    /// <summary>建一个真库，读回它实际的表结构。</summary>
    private static async Task<Dictionary<string, List<(string Name, string Type)>>> ActualTablesAsync()
    {
        var directory = Path.Combine(Path.GetTempPath(), "vpsquota-schema-" + Guid.NewGuid().ToString("n"));
        var path = Path.Combine(directory, "usage.sqlite");

        await using (var store = new SqliteStore(path)) { /* 建库即可 */ }

        var result = new Dictionary<string, List<(string, string)>>();
        using (var connection = new SqliteConnection(new SqliteConnectionStringBuilder
        {
            DataSource = path,
            Mode = SqliteOpenMode.ReadOnly,
        }.ToString()))
        {
            connection.Open();
            foreach (var table in new[] { "daily_usage", "fetch_log", "server_meta" })
            {
                var columns = new List<(string, string)>();
                using var command = connection.CreateCommand();
                command.CommandText = $"PRAGMA table_info({table})";
                using var reader = command.ExecuteReader();
                while (reader.Read())
                {
                    columns.Add((reader.GetString(1), reader.GetString(2).ToUpperInvariant()));
                }
                result[table] = columns;
            }
        }

        try { Directory.Delete(directory, recursive: true); } catch (IOException) { }
        return result;
    }

    [Fact(DisplayName = "实际建出来的表结构与 shared/schema.sql 逐列一致")]
    public async Task TablesMatchSharedSchema()
    {
        var declared = DeclaredTables();
        var actual = await ActualTablesAsync();

        Assert.Equal(3, declared.Count);   // daily_usage + fetch_log + server_meta

        foreach (var (table, columns) in declared)
        {
            Assert.True(actual.ContainsKey(table), $"代码没有建出表 {table}");
            Assert.Equal(columns, actual[table]);
        }
    }

    [Fact(DisplayName = "索引也一并建出来了")]
    public async Task IndexesExist()
    {
        var directory = Path.Combine(Path.GetTempPath(), "vpsquota-index-" + Guid.NewGuid().ToString("n"));
        var path = Path.Combine(directory, "usage.sqlite");

        await using (var store = new SqliteStore(path)) { }

        var names = new List<string>();
        using (var connection = new SqliteConnection(new SqliteConnectionStringBuilder
        {
            DataSource = path,
            Mode = SqliteOpenMode.ReadOnly,
        }.ToString()))
        {
            connection.Open();
            using var command = connection.CreateCommand();
            command.CommandText = "SELECT name FROM sqlite_master WHERE type = 'index'";
            using var reader = command.ExecuteReader();
            while (reader.Read()) names.Add(reader.GetString(0));
        }

        try { Directory.Delete(directory, recursive: true); } catch (IOException) { }

        Assert.Contains("idx_daily_usage_day", names);
        Assert.Contains("idx_fetch_log_server", names);
    }
}
