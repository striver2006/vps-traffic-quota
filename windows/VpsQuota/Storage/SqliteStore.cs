namespace VpsQuota.Storage;

using System.IO;
using Microsoft.Data.Sqlite;
using VpsQuota.Models;

/// <summary>
/// 日流量与采集日志的本地持久化。
///
/// 存在的理由：上游数据窗口有限（Vultr API 约 30 天、vnstat 日表默认保留 62 天），
/// 每次采集都覆盖式 upsert 到本地后，历史可以无限累积，单次采集失败也不会让界面变空。
///
/// 所有访问都串行化（<see cref="_gate"/>），因为刷新时多台服务器是并发采集的，
/// 而同一个 SQLite 连接不能被多个线程同时使用。
/// </summary>
public sealed class SqliteStore : IAsyncDisposable
{
    private readonly SqliteConnection _connection;
    private readonly SemaphoreSlim _gate = new(1, 1);

    public SqliteStore(string path)
    {
        var directory = Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);

        _connection = new SqliteConnection(new SqliteConnectionStringBuilder
        {
            DataSource = path,
            Mode = SqliteOpenMode.ReadWriteCreate,
        }.ToString());
        _connection.Open();
        Migrate();
    }

    /// <summary>建表语句与 shared/schema.sql 保持一致，改动时两处都要改。</summary>
    private void Migrate()
    {
        using var command = _connection.CreateCommand();
        command.CommandText = """
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS daily_usage (
                server_id TEXT    NOT NULL,
                day       TEXT    NOT NULL,
                rx_bytes  INTEGER NOT NULL,
                tx_bytes  INTEGER NOT NULL,
                PRIMARY KEY (server_id, day)
            );
            CREATE INDEX IF NOT EXISTS idx_daily_usage_day ON daily_usage (day);
            CREATE TABLE IF NOT EXISTS fetch_log (
                server_id  TEXT    NOT NULL,
                fetched_at INTEGER NOT NULL,
                ok         INTEGER NOT NULL,
                error      TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_fetch_log_server ON fetch_log (server_id, fetched_at DESC);
            """;
        command.ExecuteNonQuery();
    }

    // MARK: 写入

    /// <summary>
    /// 覆盖式写入若干天的流量。
    ///
    /// 必须是覆盖（DO UPDATE）而非忽略：当天的数据在一天之内会被反复刷新并持续增长。
    /// </summary>
    public async Task UpsertAsync(string serverId, IReadOnlyList<DailyUsage> days)
    {
        if (days.Count == 0) return;

        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            using var transaction = _connection.BeginTransaction();
            using var command = _connection.CreateCommand();
            command.Transaction = transaction;
            command.CommandText = """
                INSERT INTO daily_usage (server_id, day, rx_bytes, tx_bytes)
                VALUES ($server, $day, $rx, $tx)
                ON CONFLICT(server_id, day) DO UPDATE SET
                    rx_bytes = excluded.rx_bytes,
                    tx_bytes = excluded.tx_bytes
                """;
            var pServer = command.Parameters.Add("$server", Microsoft.Data.Sqlite.SqliteType.Text);
            var pDay = command.Parameters.Add("$day", Microsoft.Data.Sqlite.SqliteType.Text);
            var pRx = command.Parameters.Add("$rx", Microsoft.Data.Sqlite.SqliteType.Integer);
            var pTx = command.Parameters.Add("$tx", Microsoft.Data.Sqlite.SqliteType.Integer);

            pServer.Value = serverId;
            foreach (var d in days)
            {
                pDay.Value = d.Day;
                pRx.Value = d.RxBytes;
                pTx.Value = d.TxBytes;
                command.ExecuteNonQuery();
            }
            transaction.Commit();
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task LogFetchAsync(string serverId, DateTime at, bool ok, string? error)
    {
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            using var command = _connection.CreateCommand();
            command.CommandText =
                "INSERT INTO fetch_log (server_id, fetched_at, ok, error) VALUES ($s, $t, $ok, $e)";
            command.Parameters.AddWithValue("$s", serverId);
            command.Parameters.AddWithValue("$t", new DateTimeOffset(at).ToUnixTimeSeconds());
            command.Parameters.AddWithValue("$ok", ok ? 1 : 0);
            command.Parameters.AddWithValue("$e", (object?)error ?? DBNull.Value);
            command.ExecuteNonQuery();
        }
        finally
        {
            _gate.Release();
        }
    }

    // MARK: 读取

    /// <summary>
    /// 读取 <c>[from, toExclusive)</c> 区间的日流量，按日期升序。
    /// 参数是 yyyy-MM-dd 字符串 —— 该格式字典序即时间序，所以直接用文本比较即可。
    /// </summary>
    public async Task<List<DailyUsage>> DaysAsync(string serverId, string from, string toExclusive)
    {
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            using var command = _connection.CreateCommand();
            command.CommandText = """
                SELECT day, rx_bytes, tx_bytes FROM daily_usage
                WHERE server_id = $s AND day >= $from AND day < $to
                ORDER BY day ASC
                """;
            command.Parameters.AddWithValue("$s", serverId);
            command.Parameters.AddWithValue("$from", from);
            command.Parameters.AddWithValue("$to", toExclusive);

            var result = new List<DailyUsage>();
            using var reader = command.ExecuteReader();
            while (reader.Read())
            {
                result.Add(new DailyUsage(reader.GetString(0), reader.GetInt64(1), reader.GetInt64(2)));
            }
            return result;
        }
        finally
        {
            _gate.Release();
        }
    }

    /// <summary>最近一次成功采集的时间。从未成功过则返回 null。</summary>
    public async Task<DateTime?> LastSuccessAsync(string serverId)
    {
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            using var command = _connection.CreateCommand();
            command.CommandText = "SELECT MAX(fetched_at) FROM fetch_log WHERE server_id = $s AND ok = 1";
            command.Parameters.AddWithValue("$s", serverId);

            var value = command.ExecuteScalar();
            if (value is null || value == DBNull.Value) return null;
            return DateTimeOffset.FromUnixTimeSeconds(Convert.ToInt64(value)).UtcDateTime;
        }
        finally
        {
            _gate.Release();
        }
    }

    /// <summary>清理过期的采集日志，避免文件无限增长。默认保留 90 天。</summary>
    public async Task PruneFetchLogAsync(int olderThanDays, DateTime now)
    {
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            using var command = _connection.CreateCommand();
            command.CommandText = "DELETE FROM fetch_log WHERE fetched_at < $cutoff";
            command.Parameters.AddWithValue(
                "$cutoff", new DateTimeOffset(now.AddDays(-olderThanDays)).ToUnixTimeSeconds());
            command.ExecuteNonQuery();
        }
        finally
        {
            _gate.Release();
        }
    }

    public async ValueTask DisposeAsync()
    {
        await _connection.DisposeAsync().ConfigureAwait(false);
        _gate.Dispose();
    }
}
