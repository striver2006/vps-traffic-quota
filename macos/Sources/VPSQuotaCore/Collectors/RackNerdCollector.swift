import Foundation

/// 通过 RackNerd（SolusVM Client API）采集。
///
/// RackNerd VPS 多数基于 SolusVM（NerdVM 面板，默认 `https://nerdvm.racknerd.com`）。
/// 其 Client API 暴露当前计费周期内的累计带宽统计（`bw` 节点包含 `total,used,free,percent` 字节数）。
///
/// 机制与 KiwiVM 相同，采用「计数器差值」把当前账期累计值还原为每日增量：
/// - 本地快照（`racknerd-state/<serverId>.json`）记录：
///   `dayKey`（UTC 日期）、`dayStartCounter`（当日基线）、`counter`（最近观测值）。
/// - 当天用量 = 当前已用 − 当日基线，每次绝对重算，保证幂等。
/// - 换账期（计数器回落）基线归零；跨天时以昨日最终观测值作为今日基线；首次接入记入当天。
/// - 配额由 API 报告的 `total` 自动折算为 GB 并落库，当配置 `quotaGB == 0` 时自动生效。
public struct RackNerdCollector: Collector {
    private let apiKey: String
    private let apiHash: String
    private let session: URLSession
    private let endpoint: URL
    private let stateStore: RackNerdStateStore

    public static let defaultEndpoint = URL(string: "https://nerdvm.racknerd.com/api/client/command.php")!

    /// URLSession 的默认 UA 是 URL 转义后的应用名 + CFNetwork 版本；换成规范的产品 UA，让服务端能识别请求来源。
    static let userAgent = "VpsQuota/\(AppInfo.version) (macOS; +\(AppInfo.projectURL.absoluteString))"

    public init(
        apiKey: String,
        apiHash: String,
        endpoint: URL? = nil,
        session: URLSession = .shared,
        stateDirectory: URL = AppPaths.directory.appendingPathComponent("racknerd-state", isDirectory: true)
    ) {
        self.apiKey = apiKey
        self.apiHash = apiHash
        self.endpoint = endpoint ?? Self.defaultEndpoint
        self.session = session
        self.stateStore = RackNerdStateStore(directory: stateDirectory)
    }

    // MARK: - 响应模型

    struct SolusResponse: Decodable {
        let status: String?
        let statusmsg: String?
        let bw: String?
    }

    public struct ServiceSummary: Sendable {
        public let totalBytes: Int64
        public let usedBytes: Int64
        public let freeBytes: Int64
        public let percent: String
    }

    /// 拉一次 API 并解析概况。
    public func queryInfo() async throws -> ServiceSummary {
        let (status, statusmsg, bwString) = try await requestRaw()
        guard status.lowercased() == "success" else {
            let msg = statusmsg.isEmpty ? "未知错误" : statusmsg
            throw CollectError.noData("RackNerd API 报错：\(msg)。请核对 API Key 与 API Hash 是否正确。")
        }

        guard let bw = bwString, !bw.isEmpty else {
            throw CollectError.noData("RackNerd API 响应中未包含带宽数据（bw）。")
        }

        let parts = bw.components(separatedBy: ",")
        guard parts.count >= 3 else {
            throw CollectError.decode("RackNerd 带宽格式无效：\(bw)")
        }

        let total = Int64(parts[0].trimmingCharacters(in: .whitespaces)) ?? 0
        let used = Int64(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
        let free = Int64(parts[2].trimmingCharacters(in: .whitespaces)) ?? 0
        let percent = parts.count > 3 ? parts[3].trimmingCharacters(in: .whitespaces) : ""

        return ServiceSummary(totalBytes: total, usedBytes: used, freeBytes: free, percent: percent)
    }

    // MARK: - Collector

    public func fetch(server: ServerConfig, since: Date) async throws -> CollectResult {
        try await fetch(server: server, since: since, now: Date())
    }

    func fetch(server: ServerConfig, since: Date, now: Date) async throws -> CollectResult {
        guard !apiKey.isEmpty && !apiHash.isEmpty else {
            throw CollectError.misconfigured("尚未设置服务器「\(server.name)」的 RackNerd API Key 或 API Hash")
        }

        let summary = try await queryInfo()
        let today = UTCDay.string(from: now)
        let (days, snapshot) = Self.derive(
            today: today,
            counter: summary.usedBytes,
            previous: stateStore.load(serverId: server.id)
        )

        do {
            try stateStore.save(serverId: server.id, snapshot: snapshot)
        } catch {
            throw CollectError.noData("""
                无法保存 RackNerd 采集状态（\(stateStore.fileURL(serverId: server.id).path)）：\
                \(error.localizedDescription)。为避免流量被重复计算，本轮结果已丢弃
                """)
        }

        return CollectResult(
            days: days,
            reportedQuotaGB: summary.totalBytes > 0 ? Double(summary.totalBytes) / 1_073_741_824 : nil,
            warnings: []
        )
    }

    // MARK: - 差值算法

    public struct Snapshot: Codable, Equatable, Sendable {
        public var dayKey: String
        public var dayStartCounter: Int64
        public var counter: Int64

        public init(dayKey: String, dayStartCounter: Int64, counter: Int64) {
            self.dayKey = dayKey
            self.dayStartCounter = dayStartCounter
            self.counter = counter
        }
    }

    public static func derive(
        today: String,
        counter: Int64,
        previous: Snapshot?
    ) -> (days: [DailyUsage], snapshot: Snapshot) {
        let base: Int64
        if let prev = previous {
            if counter < prev.counter {
                // 计数器回落：换账期
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
            counter: counter
        )
        return ([DailyUsage(day: today, rxBytes: 0, txBytes: dayBytes)], snapshot)
    }

    // MARK: - 网络请求与容错解析

    /// 2026-10 起 nerdvm.racknerd.com 整站开启 Cloudflare bot 质询（403 + "Just a moment..." 页面，
    /// 响应头 Cf-Mitigated: challenge），原生 HTTP 客户端无法通过。若把质询页 HTML 原样透出，
    /// 用户会误以为是自己密钥配错，这里识别出来并写明原因与出路。与 Windows 端 BuildHttpError 逐条对应。
    static func buildHttpError(status: Int, cfMitigated: String?, body: String) -> CollectError {
        let challenged = (status == 403 || status == 503)
            && (cfMitigated?.lowercased() == "challenge"
                || body.contains("Just a moment")
                || body.contains("Checking your browser"))
        if challenged {
            return .noData(
                "RackNerd 端点被 Cloudflare 人机验证拦截（HTTP \(status)）。"
                + "这是 RackNerd 服务端的防护，API Key 与 API Hash 并没有问题："
                + "可尝试把端点 URL 换成 VPS 开通邮件中的控制面板地址；"
                + "仍失败时请向 RackNerd 提工单，要求对 API 放行。")
        }
        return .http(status: status, body: body)
    }

    private func requestRaw() async throws -> (status: String, statusmsg: String, bw: String?) {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        var queryItems = components?.queryItems ?? []
        queryItems.append(contentsOf: [
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "hash", value: apiHash),
            URLQueryItem(name: "action", value: "info"),
            URLQueryItem(name: "bw", value: "true"),
            URLQueryItem(name: "rdtype", value: "json"),
        ])
        components?.queryItems = queryItems

        guard let url = components?.url else {
            throw CollectError.misconfigured("无效的 RackNerd 端点 URL：\(endpoint)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CollectError.decode("非 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.buildHttpError(
                status: http.statusCode,
                cfMitigated: http.value(forHTTPHeaderField: "cf-mitigated"),
                body: String(data: data, encoding: .utf8) ?? "")
        }

        // 尝试 JSON 解析
        if let json = try? JSONDecoder().decode(SolusResponse.self, from: data) {
            return (json.status ?? "", json.statusmsg ?? "", json.bw)
        }

        // 容错：有些 SolusVM 版本可能忽略 rdtype=json 返回 XML
        let rawText = String(data: data, encoding: .utf8) ?? ""
        let status = extractXmlTag(from: rawText, tag: "status") ?? ""
        let statusmsg = extractXmlTag(from: rawText, tag: "statusmsg") ?? ""
        let bw = extractXmlTag(from: rawText, tag: "bw")

        if !status.isEmpty || bw != nil {
            return (status, statusmsg, bw)
        }

        throw CollectError.decode("无法解析 RackNerd API 返回内容：\(rawText.prefix(200))")
    }

    private func extractXmlTag(from text: String, tag: String) -> String? {
        let pattern = "<\(tag)>(.*?)</\(tag)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct RackNerdStateStore: Sendable {
    let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func load(serverId: String) -> RackNerdCollector.Snapshot? {
        guard let data = try? Data(contentsOf: fileURL(serverId: serverId)) else { return nil }
        return try? JSONDecoder().decode(RackNerdCollector.Snapshot.self, from: data)
    }

    public func save(serverId: String, snapshot: RackNerdCollector.Snapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL(serverId: serverId), options: .atomic)
    }

    public func fileURL(serverId: String) -> URL {
        let safe = serverId.map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce(into: "") { $0.append($1) }
        return directory.appendingPathComponent("\(safe).json")
    }
}
