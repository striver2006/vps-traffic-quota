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
            -- 诊断用的 CLI 与本应用可能同时开着同一个库（README 就是这么建议排查的）。
            -- 没有 busy handler 时，SQLite 撞上锁会立刻返回 SQLITE_BUSY，
            -- 一次本来成功的采集就被记成失败、数据也丢了。等 5 秒足够让对方写完。
            PRAGMA busy_timeout = 5000;
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
            CREATE TABLE IF NOT EXISTS server_meta (
                server_id         TEXT NOT NULL,
                reported_quota_gb REAL,
                PRIMARY KEY (server_id)
            );
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
            // 必须先定 Kind：DateTimeOffset(DateTime) 对 Unspecified 按本地时区解释，
            // 时间戳会整体偏移数小时，「上次刷新于」就跟着错。
            command.Parameters.AddWithValue("$t", ToUnixSeconds(at));
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

    /// <summary>
    /// 记下上游报告的配额（目前只有 Vultr 有）。传 null 表示"这次没拿到"，不覆盖已有值。
    /// </summary>
    public async Task SetReportedQuotaAsync(string serverId, double? quotaGB)
    {
        if (quotaGB is not { } value) return;

        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            using var command = _connection.CreateCommand();
            command.CommandText =
                "INSERT INTO server_meta (server_id, reported_quota_gb) VALUES ($s, $q) " +
                "ON CONFLICT(server_id) DO UPDATE SET reported_quota_gb = excluded.reported_quota_gb";
            command.Parameters.AddWithValue("$s", serverId);
            command.Parameters.AddWithValue("$q", value);
            command.ExecuteNonQuery();
        }
        finally
        {
            _gate.Release();
        }
    }

    /// <summary>读回上游报告的配额。没记录过则为 null。</summary>
    public async Task<double?> ReportedQuotaAsync(string serverId)
    {
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            using var command = _connection.CreateCommand();
            command.CommandText = "SELECT reported_quota_gb FROM server_meta WHERE server_id = $s";
            command.Parameters.AddWithValue("$s", serverId);

            var value = command.ExecuteScalar();
            if (value is null || value == DBNull.Value) return null;
            return Convert.ToDouble(value);
        }
        finally
        {
            _gate.Release();
        }
    }

    /// <summary>最近一次采集的错误。若最近一次是成功的则返回 null。</summary>
    /// <remarks>
    /// 语义与内存里那份 LastErrors 一致：成功一次就把错误清掉。
    /// 有了它，应用重启后不必等第一轮采集跑完，也能如实显示上次的失败原因（P5）。
    /// </remarks>
    public async Task<string?> LastErrorAsync(string serverId)
    {
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            using var command = _connection.CreateCommand();
            command.CommandText =
                "SELECT ok, error FROM fetch_log WHERE server_id = $s " +
                "ORDER BY fetched_at DESC LIMIT 1";
            command.Parameters.AddWithValue("$s", serverId);

            using var reader = command.ExecuteReader();
            if (!reader.Read()) return null;
            if (reader.GetInt32(0) != 0) return null;      // 最近一次是成功的
            return reader.IsDBNull(1) ? null : reader.GetString(1);
        }
        finally
        {
            _gate.Release();
        }
    }

    /// <summary>
    /// 折算成 Unix 秒。Local 按时区换算；Unspecified 视作已经是 UTC ——
    /// 应用内的时间全部来自 DateTime.UtcNow，但类型系统拦不住误传，这里兜一层。
    /// </summary>
    private static long ToUnixSeconds(DateTime value) => value.Kind switch
    {
        DateTimeKind.Utc => new DateTimeOffset(value).ToUnixTimeSeconds(),
        DateTimeKind.Local => new DateTimeOffset(value).ToUniversalTime().ToUnixTimeSeconds(),
        _ => new DateTimeOffset(DateTime.SpecifyKind(value, DateTimeKind.Utc)).ToUnixTimeSeconds(),
    };

    /// <summary>清理过期的采集日志，避免文件无限增长。默认保留 90 天。</summary>
    public async Task PruneFetchLogAsync(int olderThanDays, DateTime now)
    {
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            using var command = _connection.CreateCommand();
            command.CommandText = "DELETE FROM fetch_log WHERE fetched_at < $cutoff";
            command.Parameters.AddWithValue("$cutoff", ToUnixSeconds(now.AddDays(-olderThanDays)));
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
