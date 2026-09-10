-- VPS Traffic Quota —— 本地存储 schema（macOS 与 Windows 两端共用的唯一事实源）
--
-- 设计要点：
--   * daily_usage 以 (server_id, day) 为主键，采集时对账期内每一天做覆盖式 upsert。
--     当天的流量会持续增长，所以必须覆盖而不是忽略冲突。
--   * 上游数据窗口有限（Vultr API 约 30 天、vnstat 日数据默认保留 62 天），
--     本地持续 upsert 后即可留存任意长的历史，也能容忍某次采集失败。
--   * 所有 day 一律使用 UTC 的 YYYY-MM-DD。Vultr 的日期键本身就是 UTC；
--     vnstat 侧在采集时按服务器本地时区读出后统一归到 UTC 日期。

CREATE TABLE IF NOT EXISTS daily_usage (
    server_id TEXT    NOT NULL,
    day       TEXT    NOT NULL,          -- YYYY-MM-DD (UTC)
    rx_bytes  INTEGER NOT NULL,
    tx_bytes  INTEGER NOT NULL,
    PRIMARY KEY (server_id, day)
);

CREATE INDEX IF NOT EXISTS idx_daily_usage_day ON daily_usage (day);

-- 每次采集的结果记录，用于在 UI 上显示"上次成功刷新时间"和失败原因。
CREATE TABLE IF NOT EXISTS fetch_log (
    server_id  TEXT    NOT NULL,
    fetched_at INTEGER NOT NULL,         -- Unix 时间戳（秒）
    ok         INTEGER NOT NULL,         -- 1 成功 / 0 失败
    error      TEXT                      -- 失败时的原始错误文本，成功时为 NULL
);

CREATE INDEX IF NOT EXISTS idx_fetch_log_server ON fetch_log (server_id, fetched_at DESC);

-- 每台服务器的上游元数据，目前只有 Vultr API 报告的配额（allowed_bandwidth）。
--
-- 为什么要落盘：配额只在采集成功时才拿得到，而 quotaGB 填 0 的 Vultr 实例
-- （文档推荐的用法）在重启后到首次采集成功之间就会变成"配额未知"——
-- 进度条消失、常驻区只剩一道短横。S3 要求采集失败时继续显示上次成功的数据，
-- 离线启动这条路径下必须也成立。
CREATE TABLE IF NOT EXISTS server_meta (
    server_id         TEXT NOT NULL,
    reported_quota_gb REAL,                -- 上游报告的月配额（GB）；未知为 NULL
    PRIMARY KEY (server_id)
);
