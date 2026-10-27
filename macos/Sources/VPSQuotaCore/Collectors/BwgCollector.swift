import Foundation

/// 通过搬瓦工（BandwagonHost）KiwiVM API 采集。
///
/// KiwiVM 只暴露一个**账期累计计数器**：`getServiceInfo` 的 `data_counter` 是本计费
/// 周期开始以来的计费字节总量，没有按天的历史序列（`getRawUsageStats` 的明细是
/// Detailed Statistics 的原始采样，不含计费系数，窗口也短，撑不起一个账期）。
/// 所以这里用「计数器差值」把累计值还原成按天用量：
///
/// - 本地状态文件（`bwg-state/<veid>.json`，与应用数据库同目录）记一份快照：
///   `dayKey`（快照所属 UTC 日）、`dayStartCounter`（当日基线）、`counter`（最近观测值）、
///   `nextReset`（重置时间戳，用于识别换账期）。
/// - 当天用量 = 当前计数器 − 当日基线，**每次都绝对重算**。于是覆盖式 upsert 天然幂等，
///   某一轮落库失败也不会让数字错位 —— 下一轮重算的还是同一个绝对值。
/// - 跨天时取「昨天最后一次观测值」当今天的基线；应用停采期间的增量会整段记到
///   恢复采集的那一天（总量仍然正确，只是那天的柱子偏高）。
/// - 换账期（计数器回落，或 `data_next_reset` 变化）时基线归零。
/// - 首次接入没有快照：基线取 0，**整个已用计数器都记到当天**。账期总量因此立即与
///   面板一致，代价是趋势图首日有一根大柱子。此时不要再填「起始已用量」，
///   否则同一个缺口被补两遍。
///
/// 计数器与配额按官方要求都要乘 `monthly_data_multiplier`（部分机房带宽更贵，
/// 系数小于 1），折算在这一层完成，往下各层拿到的是已按计费口径的字节数 ——
/// 与 KiwiVM 面板显示的数字同口径。计数器是单一计费值（进出已合算），
/// 记在 tx 一栏、rx 恒为 0，服务器的计费口径应保持「仅出站」。
///
/// 鉴权走查询参数 `veid` + `api_key`（KiwiVM 的固定方案），每个 VEID 有自己的 Key，
/// 与 Vultr 的账号级 Key 不同。官方有速率限制（15 分钟 / 24 小时两档积分），
/// 刷新周期不必低于 60 分钟。
public struct BwgCollector: Collector {
    private let apiKey: String
    private let session: URLSession
    private let baseURL: URL
    private let stateStore: BwgStateStore

    public init(
        apiKey: String,
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://api.64clouds.com/v1")!,
        stateDirectory: URL = AppPaths.directory.appendingPathComponent("bwg-state", isDirectory: true)
    ) {
        self.apiKey = apiKey
        self.session = session
        self.baseURL = baseURL
        self.stateStore = BwgStateStore(directory: stateDirectory)
    }

    // MARK: - 响应模型

    struct ServiceInfoResponse: Decodable {
        let error: Int?
        let message: String?
        let plan: String?
        let nodeLocation: String?
        let planMonthlyData: Int64?
        let dataCounter: Int64?
        let monthlyDataMultiplier: Double?
        let dataNextReset: Int64?
        let suspended: FlexibleBool?

        enum CodingKeys: String, CodingKey {
            case error, message, plan
            case nodeLocation = "node_location"
            case planMonthlyData = "plan_monthly_data"
            case dataCounter = "data_counter"
            case monthlyDataMultiplier = "monthly_data_multiplier"
            case dataNextReset = "data_next_reset"
            case suspended
        }
    }

    /// KiwiVM 的布尔字段新旧版本一会儿给 `true/false`、一会儿给 `0/1`，两种都收。
    struct FlexibleBool: Decodable {
        let value: Bool

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let b = try? c.decode(Bool.self) {
                self.value = b
            } else {
                self.value = try c.decode(Int.self) != 0
            }
        }
    }

    /// 供 CLI probe 与 fetch 共用的服务概况。字节数均已乘 `monthly_data_multiplier`。
    public struct ServiceSummary: Sendable {
        public let plan: String?
        public let nodeLocation: String?
        public let usedBytes: Int64
        public let quotaBytes: Int64
        public let nextReset: Date?
        public let suspended: Bool
    }

    /// 拉一次 `getServiceInfo` 并折成概况。
    public func serviceInfo(veid: String) async throws -> ServiceSummary {
        let info: ServiceInfoResponse = try await get(path: "getServiceInfo", veid: veid)
        if let code = info.error, code != 0 {
            throw CollectError.noData(Self.apiErrorMessage(code: code, message: info.message))
        }

        let multiplier = info.monthlyDataMultiplier ?? 1
        return ServiceSummary(
            plan: info.plan,
            nodeLocation: info.nodeLocation,
            usedBytes: Self.billedBytes(info.dataCounter ?? 0, multiplier: multiplier),
            quotaBytes: Self.billedBytes(info.planMonthlyData ?? 0, multiplier: multiplier),
            nextReset: info.dataNextReset.flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil },
            suspended: info.suspended?.value == true
        )
    }

    // MARK: - Collector

    public func fetch(server: ServerConfig, since: Date) async throws -> CollectResult {
        try await fetch(server: server, since: since, now: Date())
    }

    /// `now` 单独传入纯粹是为了可测，协议方法固定用当前时间。
    func fetch(server: ServerConfig, since: Date, now: Date) async throws -> CollectResult {
        guard let veid = server.bwgVeid?.trimmingCharacters(in: .whitespacesAndNewlines), !veid.isEmpty else {
            throw CollectError.misconfigured("服务器「\(server.name)」未填写搬瓦工 VEID")
        }
        guard !apiKey.isEmpty else {
            throw CollectError.misconfigured("尚未设置这台服务器的 KiwiVM API Key")
        }

        let info: ServiceInfoResponse = try await get(path: "getServiceInfo", veid: veid)
        if let code = info.error, code != 0 {
            throw CollectError.noData(Self.apiErrorMessage(code: code, message: info.message))
        }

        let multiplier = info.monthlyDataMultiplier ?? 1
        let counter = Self.billedBytes(info.dataCounter ?? 0, multiplier: multiplier)
        let nextReset = info.dataNextReset ?? 0

        var warnings: [String] = []
        if info.suspended?.value == true {
            warnings.append("KiwiVM 报告该 VPS 当前处于暂停（suspended）状态")
        }
        if let mismatch = Self.resetDayMismatch(configured: server.resetDay, nextReset: nextReset) {
            warnings.append("""
                KiwiVM 面板的流量重置日是每月 \(mismatch.actual) 号，\
                与配置的重置日 \(server.resetDay) 号推算的不一致，账期切分会有偏差。\
                请对照 KiwiVM 面板的「下次重置」修正「每月重置日」
                """)
        }

        let today = UTCDay.string(from: now)
        let (days, snapshot) = Self.derive(
            today: today,
            counter: counter,
            nextReset: nextReset,
            previous: stateStore.load(veid: veid)
        )

        // 状态必须先于返回值落盘：快照推进不了，这次的结果就不能用 ——
        // 否则下一轮会把同一段流量再记一遍。落盘失败时宁可这轮采集失败。
        do {
            try stateStore.save(veid: veid, snapshot: snapshot)
        } catch {
            throw CollectError.noData("""
                无法保存搬瓦工采集状态（\(stateStore.fileURL(veid: veid).path)）：\
                \(error.localizedDescription)。为避免流量被重复计算，本轮结果已丢弃
                """)
        }

        let quotaBytes = Self.billedBytes(info.planMonthlyData ?? 0, multiplier: multiplier)
        return CollectResult(
            days: days,
            reportedQuotaGB: quotaBytes > 0 ? Double(quotaBytes) / 1_073_741_824 : nil,
            warnings: warnings
        )
    }

    // MARK: - 差值算法（纯函数，可单测）

    struct Snapshot: Codable, Equatable {
        /// 快照所属的 UTC 日（YYYY-MM-DD）。
        var dayKey: String
        /// 当日基线：该日开始（或首次观测）时的计数器。
        var dayStartCounter: Int64
        /// 最近一次观测到的计数器。
        var counter: Int64
        /// 最近一次观测到的 data_next_reset，用于识别换账期。
        var nextReset: Int64
    }

    /// 由「上次快照 + 本次观测」推出今天应记录的用量与新快照。
    ///
    /// 基线的取法（按优先级）：
    /// 1. 换账期（计数器回落或 nextReset 变化）→ 0，整个新计数器都是本账期的；
    /// 2. 还是同一天 → 上次的当日基线，用量随观测绝对增长（幂等）；
    /// 3. 跨到新的一天 → 上次观测值当作今天的起点（停采期间的增量落在新一天）。
    static func derive(
        today: String,
        counter: Int64,
        nextReset: Int64,
        previous: Snapshot?
    ) -> (days: [DailyUsage], snapshot: Snapshot) {
        let base: Int64
        if let prev = previous {
            if counter < prev.counter || nextReset != prev.nextReset {
                base = 0
            } else if prev.dayKey == today {
                base = prev.dayStartCounter
            } else {
                base = prev.counter
            }
        } else {
            base = 0
        }

        let dayBytes = max(0, counter - base)
        let snapshot = Snapshot(
            dayKey: today,
            dayStartCounter: base,
            counter: counter,
            nextReset: nextReset
        )
        return ([DailyUsage(day: today, rxBytes: 0, txBytes: dayBytes)], snapshot)
    }

    /// 官方口径：`data_counter` / `plan_monthly_data` 都要乘 `monthly_data_multiplier`。
    static func billedBytes(_ raw: Int64, multiplier: Double) -> Int64 {
        Int64((Double(raw) * multiplier).rounded())
    }

    static func apiErrorMessage(code: Int, message: String?) -> String {
        let detail = message.flatMap { $0.isEmpty ? nil : $0 } ?? "未知错误"
        return "KiwiVM API 报错（error \(code)）：\(detail)。请核对 VEID 与 API Key 是否匹配。"
    }

    /// 校验配置的重置日与面板报告的是否一致。
    ///
    /// 返回 nil 表示一致（或上游没给 `data_next_reset`，无从校验）；
    /// 否则返回实际日号与配置日（按月末钳制后）的期望值，供警告文案使用。
    /// 「月末钳制」语义与 BillingPeriod 相同：31 号遇上 2 月按 28/29 号算。
    static func resetDayMismatch(configured: Int, nextReset: Int64) -> (actual: Int, expected: Int)? {
        guard nextReset > 0 else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!

        let date = Date(timeIntervalSince1970: TimeInterval(nextReset))
        let comps = cal.dateComponents([.day], from: date)
        guard let actual = comps.day else { return nil }

        let daysInMonth = cal.range(of: .day, in: .month, for: date)?.count ?? 30
        let expected = min(max(configured, 1), daysInMonth)
        return actual == expected ? nil : (actual, expected)
    }

    // MARK: - HTTP

    private func get<T: Decodable>(path: String, veid: String) async throws -> T {
        guard !apiKey.isEmpty else {
            throw CollectError.misconfigured("尚未设置这台服务器的 KiwiVM API Key")
        }

        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "veid", value: veid),
            URLQueryItem(name: "api_key", value: apiKey),
        ]
        guard let url = components?.url else {
            throw CollectError.misconfigured("无效的请求路径：\(path)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CollectError.decode("非 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CollectError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw CollectError.decode(error.localizedDescription)
        }
    }
}

/// 每个 VEID 一份的采集快照，落在应用数据目录的 `bwg-state/` 下。
///
/// 一台一个文件而不是全挤一个 JSON：并发采集不同 VEID 时互不干扰，
/// 不需要加锁。读写都做原子替换（tmp + rename），写失败由调用方决定是否算采集失败。
struct BwgStateStore {
    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    /// 读不到（不存在 / 解析失败）一律返回 nil —— 调用方按「首次观测」处理，
    /// 紧随其后的 save 会重写掉坏文件。
    func load(veid: String) -> BwgCollector.Snapshot? {
        guard let data = try? Data(contentsOf: fileURL(veid: veid)) else { return nil }
        return try? JSONDecoder().decode(BwgCollector.Snapshot.self, from: data)
    }

    func save(veid: String, snapshot: BwgCollector.Snapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        // .atomic 先写临时文件再替换，中途崩溃不会留下半个 JSON。
        try data.write(to: fileURL(veid: veid), options: .atomic)
    }

    func fileURL(veid: String) -> URL {
        // VEID 理论上是纯数字；万一混进别的字符也别让它跑出目录。
        let safe = veid.map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce(into: "") { $0.append($1) }
        return directory.appendingPathComponent("\(safe).json")
    }
}
