import Foundation

/// 采集调度与状态汇总。
///
/// 是 UI 与 CLI 共同的入口：负责并发采集、落库、以及把本地数据折算成 `ServerStatus`。
/// 用 `actor` 保护配置与缓存 —— 刷新是并发的，UI 也可能随时改配置。
public actor TrafficMonitor {
    private let store: SQLiteStore
    private var config: AppConfig
    private var vultrAPIKey: String?

    /// Vultr 报告的配额缓存。只在用户没手填配额时才有意义，
    /// 缓存它是为了让"离线读本地数据"这条路径也能显示出配额。
    private var reportedQuotaCache: [String: Double] = [:]
    /// 最近一次采集的错误与提醒，按 serverId 索引。
    private var lastErrors: [String: String] = [:]
    private var lastWarnings: [String: [String]] = [:]

    public init(store: SQLiteStore, config: AppConfig, vultrAPIKey: String?) {
        self.store = store
        self.config = config
        self.vultrAPIKey = vultrAPIKey
    }

    public func updateConfig(_ config: AppConfig) {
        self.config = config
    }

    public func setVultrAPIKey(_ key: String?) {
        self.vultrAPIKey = key
    }

    public func currentConfig() -> AppConfig { config }

    // MARK: - 刷新

    /// 并发采集所有服务器，落库后返回最新状态。
    ///
    /// 单台失败不影响其他台：错误被记入 `fetch_log` 并挂在该台的 `lastError` 上，
    /// 界面依然显示它上次成功采集到的数据。这一点很重要 —— 一台机器 SSH 不通
    /// 不应该让整个面板变成空白。
    public func refreshAll() async -> [ServerStatus] {
        let servers = config.servers
        let now = Date()

        await withTaskGroup(of: Void.self) { group in
            for server in servers {
                group.addTask { [self] in
                    // 单台的失败已经落进 fetch_log 和 lastErrors，这里不需要返回值。
                    _ = await refreshOne(server: server, now: now)
                }
            }
        }

        try? await store.pruneFetchLog()
        return await statuses(now: now)
    }

    /// 只刷新一台，供设置界面的"测试连接"使用。返回 nil 表示成功。
    public func refreshOne(server: ServerConfig, now: Date = Date()) async -> String? {
        let period = BillingPeriod.current(resetDay: server.resetDay, now: now)

        do {
            let collector = try makeCollector(for: server)
            let result = try await collector.fetch(server: server, since: period.start)

            try await store.upsert(serverId: server.id, days: result.days)
            try await store.logFetch(serverId: server.id, at: now, ok: true, error: nil)

            if let quota = result.reportedQuotaGB {
                reportedQuotaCache[server.id] = quota
            }
            lastErrors[server.id] = nil
            lastWarnings[server.id] = result.warnings
            return nil
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            lastErrors[server.id] = message
            try? await store.logFetch(serverId: server.id, at: now, ok: false, error: message)
            return message
        }
    }

    // MARK: - 读取状态

    /// 只读本地数据库计算状态，不发起任何网络请求。
    ///
    /// 应用启动时先走这条，界面立刻有内容，再在后台发起真正的刷新。
    public func statuses(now: Date = Date()) async -> [ServerStatus] {
        var result: [ServerStatus] = []
        for server in config.servers {
            let period = BillingPeriod.current(resetDay: server.resetDay, now: now)
            let days = (try? await store.days(
                serverId: server.id,
                from: period.startDay,
                toExclusive: period.endDayExclusive
            )) ?? []
            let lastSuccess = try? await store.lastSuccess(serverId: server.id)

            result.append(QuotaCalculator.status(
                server: server,
                days: days,
                now: now,
                apiQuotaGB: reportedQuotaCache[server.id],
                lastSuccessAt: lastSuccess ?? nil,
                lastError: lastErrors[server.id],
                warnings: lastWarnings[server.id] ?? []
            ))
        }
        return result
    }

    /// 取某台服务器指定天数内的历史，用于趋势图（可跨账期）。
    public func history(serverId: String, days count: Int, now: Date = Date()) async -> [DailyUsage] {
        let from = UTCDay.string(from: now.addingTimeInterval(-Double(count) * 86_400))
        let to = UTCDay.string(from: now.addingTimeInterval(86_400))
        return (try? await store.days(serverId: serverId, from: from, toExclusive: to)) ?? []
    }

    // MARK: -

    private func makeCollector(for server: ServerConfig) throws -> any Collector {
        switch server.provider {
        case .vultr:
            guard let key = vultrAPIKey, !key.isEmpty else {
                throw CollectError.misconfigured("尚未设置 Vultr API Key，请在设置中填写")
            }
            return VultrCollector(apiKey: key)
        case .ssh:
            return SSHVnstatCollector()
        }
    }
}
