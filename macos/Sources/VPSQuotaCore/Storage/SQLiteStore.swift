import Foundation
import SQLite3

/// SQLite 需要的字符串绑定语义：告诉 SQLite 自行拷贝入参，
/// 否则 Swift 侧的临时字符串在 step 之前就可能被释放。
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum StoreError: LocalizedError {
    case open(String)
    case sql(String)

    public var errorDescription: String? {
        switch self {
        case .open(let m): return "无法打开本地数据库：\(m)"
        case .sql(let m): return "数据库操作失败：\(m)"
        }
    }
}

/// 日流量与采集日志的本地持久化。
///
/// 存在的理由：上游数据窗口有限（Vultr API 约 30 天、vnstat 日表默认保留 62 天），
/// 每次采集都覆盖式 upsert 到本地后，历史可以无限累积，单次采集失败也不会让界面变空。
///
/// 用 `actor` 串行化所有访问，因为 SQLite 连接不是线程安全的，
/// 而刷新时四台服务器是并发采集的。
public actor SQLiteStore {
    /// 连接句柄本身在 init 之后不再变动，所以标 `nonisolated(unsafe)` 让 deinit 能关闭它；
    /// 对该连接的所有**使用**仍然由 actor 串行化 —— SQLite 连接不是线程安全的。
    private nonisolated(unsafe) let db: OpaquePointer

    public init(path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var handle: OpaquePointer?
        guard sqlite3_open(path.path, &handle) == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            throw StoreError.open(msg)
        }
        self.db = handle

        // 诊断用的 CLI 与图形界面可能同时开着同一个库（README 就是这么建议排查的）。
        // 没有 busy handler 时，SQLite 撞上锁会立刻返回 SQLITE_BUSY，
        // upsert 的 BEGIN IMMEDIATE 直接失败 —— 一次本来成功的采集被记成失败、数据也丢了。
        sqlite3_busy_timeout(handle, 5_000)

        try Self.migrate(handle)
    }

    deinit {
        sqlite3_close(db)
    }

    /// 建表语句与 shared/schema.sql 保持一致，改动时两处都要改。
    ///
    /// 是静态函数而非实例方法：actor 的 `init` 处于 nonisolated 上下文，无法调用隔离成员。
    private static func migrate(_ handle: OpaquePointer) throws {
        let sql = """
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
        """
        try exec(handle, sql)
    }

    private static func exec(_ handle: OpaquePointer?, _ sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &errMsg) == SQLITE_OK else {
            let msg = errMsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errMsg)
            throw StoreError.sql(msg)
        }
    }

    private func exec(_ sql: String) throws {
        try Self.exec(db, sql)
    }

    private func lastErrorMessage() -> String {
        String(cString: sqlite3_errmsg(db))
    }

    // MARK: - 写入

    /// 覆盖式写入若干天的流量。
    ///
    /// 必须是覆盖（`DO UPDATE`）而非忽略：当天的数据在一天之内会被反复刷新并持续增长。
    public func upsert(serverId: String, days: [DailyUsage]) throws {
        guard !days.isEmpty else { return }

        try exec("BEGIN IMMEDIATE")
        do {
            let sql = """
            INSERT INTO daily_usage (server_id, day, rx_bytes, tx_bytes)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(server_id, day) DO UPDATE SET
                rx_bytes = excluded.rx_bytes,
                tx_bytes = excluded.tx_bytes
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw StoreError.sql(lastErrorMessage())
            }
            defer { sqlite3_finalize(stmt) }

            for d in days {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                sqlite3_bind_text(stmt, 1, serverId, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, d.day, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(stmt, 3, d.rxBytes)
                sqlite3_bind_int64(stmt, 4, d.txBytes)
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw StoreError.sql(lastErrorMessage())
                }
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    public func logFetch(serverId: String, at date: Date, ok: Bool, error: String?) throws {
        let sql = "INSERT INTO fetch_log (server_id, fetched_at, ok, error) VALUES (?, ?, ?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.sql(lastErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, serverId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 2, Int64(date.timeIntervalSince1970))
        sqlite3_bind_int(stmt, 3, ok ? 1 : 0)
        if let error {
            sqlite3_bind_text(stmt, 4, error, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 4)
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StoreError.sql(lastErrorMessage())
        }
    }

    // MARK: - 读取

    /// 读取 `[from, toExclusive)` 区间的日流量，按日期升序。
    ///
    /// 参数是 `YYYY-MM-DD` 字符串 —— 该格式字典序即时间序，所以直接用文本比较即可。
    public func days(serverId: String, from: String, toExclusive: String) throws -> [DailyUsage] {
        let sql = """
        SELECT day, rx_bytes, tx_bytes FROM daily_usage
        WHERE server_id = ? AND day >= ? AND day < ?
        ORDER BY day ASC
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.sql(lastErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, serverId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, from, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, toExclusive, -1, SQLITE_TRANSIENT)

        var result: [DailyUsage] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let dayPtr = sqlite3_column_text(stmt, 0) else { continue }
            result.append(DailyUsage(
                day: String(cString: dayPtr),
                rxBytes: sqlite3_column_int64(stmt, 1),
                txBytes: sqlite3_column_int64(stmt, 2)
            ))
        }
        return result
    }

    /// 最近一次成功采集的时间。从未成功过则返回 nil。
    public func lastSuccess(serverId: String) throws -> Date? {
        let sql = "SELECT MAX(fetched_at) FROM fetch_log WHERE server_id = ? AND ok = 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.sql(lastErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, serverId, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW,
              sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 0)))
    }

    /// 清理过期的采集日志，避免文件无限增长。默认保留 90 天。
    public func pruneFetchLog(olderThan days: Int = 90, now: Date = Date()) throws {
        let cutoff = Int64(now.addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970)
        try exec("DELETE FROM fetch_log WHERE fetched_at < \(cutoff)")
    }
}
