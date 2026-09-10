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
    /// 值是 `String?` 而不是 `String`：需要区分「这一轮还没采过」（键不存在，回落读库）
    /// 与「这一轮采成功了，没有错误」（键存在、值为 nil，不该再把库里的旧错误捞回来）。
    private var lastErrors: [String: String?] = [:]
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

        // 本轮所有配额未手填的 Vultr 实例共用一次实例列表请求。
        // 每台各拉一次的话，返回的其实是同一份数据，白白逼近上游的速率限制。
        let quotaLookup = await fetchVultrQuotas(servers: servers)

        await withTaskGroup(of: Void.self) { group in
            for server in servers {
                group.addTask { [self] in
                    // 单台的失败已经落进 fetch_log 和 lastErrors，这里不需要返回值。
                    _ = await refreshOne(server: server, now: now, quotaLookup: quotaLookup)
                }
            }
        }

        try? await store.pruneFetchLog()
        return await statuses(now: now)
    }

    /// 只刷新一台，供设置界面的"测试连接"使用。返回 nil 表示成功。
    public func refreshOne(
        server: ServerConfig,
        now: Date = Date(),
        quotaLookup: [String: Double]? = nil
    ) async -> String? {
        let period = BillingPeriod.current(resetDay: server.resetDay, now: now)

        do {
            let collector = try makeCollector(for: server, quotaLookup: quotaLookup)
            let result = try await collector.fetch(server: server, since: period.start)

            try await store.upsert(serverId: server.id, days: result.days)
            try await store.logFetch(serverId: server.id, at: now, ok: true, error: nil)

            if let quota = result.reportedQuotaGB {
                reportedQuotaCache[server.id] = quota
                // 也落盘：否则重启后到首次采集成功之间，quotaGB 填 0 的 Vultr 实例
                // 会显示成"配额未知"，进度条消失（S3）。
                try? await store.setReportedQuota(serverId: server.id, quotaGB: quota)
            }
            // 置空而不是移除：statuses() 会用「内存里没有」作为回落读库的信号，
            // 移除的话刚采集成功的这台又会把库里那条旧错误捞回来。
            lastErrors.updateValue(nil, forKey: server.id)
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

            // 配额与错误都优先用本轮内存里的，没有再回落到库里 ——
            // 这样应用刚启动、一次都还没采集时，界面显示的也是上次退出前的真实状况，
            // 而不是"配额未知 + 一切正常"这种看起来没问题的假象（P5 / S3）。
            let quota: Double?
            if let cached = reportedQuotaCache[server.id] {
                quota = cached
            } else {
                quota = (try? await store.reportedQuota(serverId: server.id)) ?? nil
            }
            let error: String?
            if let thisRound = lastErrors[server.id] {
                error = thisRound
            } else {
                error = (try? await store.lastError(serverId: server.id)) ?? nil
            }

            result.append(QuotaCalculator.status(
                server: server,
                days: days,
                now: now,
                apiQuotaGB: quota,
                lastSuccessAt: lastSuccess ?? nil,
                lastError: error,
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

    /// 一轮刷新开始时把 Vultr 的实例列表拉一次，供本轮所有 Vultr 采集共用。
    ///
    /// 没有配额未填的 Vultr 实例时不发请求；拉取失败也不算错误 ——
    /// 各台照常走自己的采集路径，只是退回到"自己去问"而已。
    private func fetchVultrQuotas(servers: [ServerConfig]) async -> [String: Double]? {
        let needsQuota = servers.contains { $0.provider == .vultr && $0.quotaGB <= 0 }
        guard needsQuota, let key = vultrAPIKey, !key.isEmpty else { return nil }

        guard let instances = try? await VultrCollector(apiKey: key).listInstances() else {
            return nil
        }
        return instances.reduce(into: [String: Double]()) { table, instance in
            if let quota = instance.allowedBandwidthGB { table[instance.id] = quota }
        }
    }

    private func makeCollector(
        for server: ServerConfig,
        quotaLookup: [String: Double]? = nil
    ) throws -> any Collector {
        switch server.provider {
        case .vultr:
            guard let key = vultrAPIKey, !key.isEmpty else {
                throw CollectError.misconfigured("尚未设置 Vultr API Key，请在设置中填写")
            }
            return VultrCollector(apiKey: key, quotaLookup: quotaLookup)
        case .ssh:
            return SSHVnstatCollector()
        }
    }
}
