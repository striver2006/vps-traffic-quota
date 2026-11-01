import Foundation

/// 通过 Hetzner Cloud 官方 REST API 采集。
///
/// Hetzner Cloud 通过 `GET /v1/servers/{id}` 暴露当月用量与配额：
/// - `outgoing_traffic`: 当前账期出站字节数（Hetzner 官方主要针对出站计费）
/// - `ingoing_traffic`: 当前账期入站字节数（通常免费，但保留用于统计）
/// - `included_traffic`: 包含的免费月流量总配额（字节数，通常 20 TB 等）
///
/// 机制与 KiwiVM 相同，采用「计数器差值」把当月累计计数器还原为每日 rx/tx：
/// - 本地快照（`hetzner-state/<serverId>.json`）记录：
///   `dayKey`、`dayStartTx`、`dayStartRx`、`txCounter`、`rxCounter`、`periodStart`。
/// - 当日用量 = 当前计数器 − 当日基线，绝对重算，天然幂等。
/// - 换账期（新账期起始日变更，或计数器回落）时基线归零。
/// - 配额由 API 报告的 `included_traffic` 自动折算为 GB 落库，当配置 `quotaGB == 0` 时自动生效。
public struct HetznerCollector: Collector {
    private let apiToken: String
    private let baseURL: URL
    private let session: URLSession
    private let stateStore: HetznerStateStore

    public init(
        apiToken: String,
        baseURL: URL = URL(string: "https://api.hetzner.cloud/v1")!,
        session: URLSession = .shared,
        stateDirectory: URL = AppPaths.directory.appendingPathComponent("hetzner-state", isDirectory: true)
    ) {
        self.apiToken = apiToken
        self.baseURL = baseURL
        self.session = session
        self.stateStore = HetznerStateStore(directory: stateDirectory)
    }

    // MARK: - 响应模型

    public struct ServerInfo: Decodable, Sendable {
        public let id: Int64
        public let name: String
        public let status: String
        public let outgoingTraffic: Int64?
        public let ingoingTraffic: Int64?
        public let includedTraffic: Int64?

        enum CodingKeys: String, CodingKey {
            case id, name, status
            case outgoingTraffic = "outgoing_traffic"
            case ingoingTraffic = "ingoing_traffic"
            case includedTraffic = "included_traffic"
        }
    }

    struct ServerWrapper: Decodable {
        let server: ServerInfo
    }

    struct ServerListWrapper: Decodable {
        let servers: [ServerInfo]
    }

    /// 列出项目下所有的云服务器（供探测与调试）。
    public func listServers() async throws -> [ServerInfo] {
        let wrapper: ServerListWrapper = try await request(path: "servers")
        return wrapper.servers
    }

    /// 查询单台云服务器。
    public func serverInfo(id: String) async throws -> ServerInfo {
        let wrapper: ServerWrapper = try await request(path: "servers/\(id)")
        return wrapper.server
    }

    // MARK: - Collector

    public func fetch(server: ServerConfig, since: Date) async throws -> CollectResult {
        try await fetch(server: server, since: since, now: Date())
    }

    func fetch(server: ServerConfig, since: Date, now: Date) async throws -> CollectResult {
        guard let serverId = server.hetznerServerId?.trimmingCharacters(in: .whitespacesAndNewlines), !serverId.isEmpty else {
            throw CollectError.misconfigured("服务器「\(server.name)」未填写 Hetzner Server ID")
        }
        guard !apiToken.isEmpty else {
            throw CollectError.misconfigured("尚未设置 Hetzner API Token，请在设置中填写")
        }

        let info = try await serverInfo(id: serverId)

        var warnings: [String] = []
        if info.status.lowercased() != "running" {
            warnings.append("Hetzner 报告该服务器状态为 \(info.status)")
        }

        let currentPeriod = BillingPeriod.current(resetDay: server.resetDay, now: now)
        let today = UTCDay.string(from: now)
        let tx = info.outgoingTraffic ?? 0
        let rx = info.ingoingTraffic ?? 0

        let (days, snapshot) = Self.derive(
            today: today,
            periodStart: currentPeriod.startDay,
            txCounter: tx,
            rxCounter: rx,
            previous: stateStore.load(serverId: server.id)
        )

        do {
            try stateStore.save(serverId: server.id, snapshot: snapshot)
        } catch {
            throw CollectError.noData("""
                无法保存 Hetzner 采集状态（\(stateStore.fileURL(serverId: server.id).path)）：\
                \(error.localizedDescription)。为避免流量被重复计算，本轮结果已丢弃
                """)
        }

        let includedBytes = info.includedTraffic ?? 0
        return CollectResult(
            days: days,
            reportedQuotaGB: includedBytes > 0 ? Double(includedBytes) / 1_073_741_824 : nil,
            warnings: warnings
        )
    }

    // MARK: - 差值算法

    public struct Snapshot: Codable, Equatable, Sendable {
        public var dayKey: String
        public var dayStartTx: Int64
        public var dayStartRx: Int64
        public var txCounter: Int64
        public var rxCounter: Int64
        public var periodStart: String

        public init(
            dayKey: String,
            dayStartTx: Int64,
            dayStartRx: Int64,
            txCounter: Int64,
            rxCounter: Int64,
            periodStart: String
        ) {
            self.dayKey = dayKey
            self.dayStartTx = dayStartTx
            self.dayStartRx = dayStartRx
            self.txCounter = txCounter
            self.rxCounter = rxCounter
            self.periodStart = periodStart
        }
    }

    public static func derive(
        today: String,
        periodStart: String,
        txCounter: Int64,
        rxCounter: Int64,
        previous: Snapshot?
    ) -> (days: [DailyUsage], snapshot: Snapshot) {
        let baseTx: Int64
        let baseRx: Int64

        if let prev = previous {
            if periodStart != prev.periodStart || txCounter < prev.txCounter {
                // 换账期或计数器回落
                baseTx = 0
                baseRx = 0
            } else if prev.dayKey == today {
                baseTx = prev.dayStartTx
                baseRx = prev.dayStartRx
            } else {
                baseTx = prev.txCounter
                baseRx = prev.rxCounter
            }
        } else {
            baseTx = 0
            baseRx = 0
        }

        let dayTx = max(0, txCounter - baseTx)
        let dayRx = max(0, rxCounter - baseRx)

        let snapshot = Snapshot(
            dayKey: today,
            dayStartTx: baseTx,
            dayStartRx: baseRx,
            txCounter: txCounter,
            rxCounter: rxCounter,
            periodStart: periodStart
        )

        return ([DailyUsage(day: today, rxBytes: dayRx, txBytes: dayTx)], snapshot)
    }

    // MARK: - 网络请求

    private func request<T: Decodable>(path: String) async throws -> T {
        guard !apiToken.isEmpty else {
            throw CollectError.misconfigured("尚未设置 Hetzner API Token")
        }

        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CollectError.decode("非 HTTP 响应")
        }

        switch http.statusCode {
        case 200..<300:
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw CollectError.decode(error.localizedDescription)
            }
        case 401:
            throw CollectError.http(status: 401, body: "Hetzner API Token 无效或已过期")
        case 403:
            throw CollectError.http(status: 403, body: "Hetzner API Token 权限不足，请确认具有读取权限")
        case 404:
            throw CollectError.http(status: 404, body: "Hetzner 未找到指定资源（\(path)）")
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw CollectError.http(status: http.statusCode, body: body)
        }
    }
}

public struct HetznerStateStore: Sendable {
    let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func load(serverId: String) -> HetznerCollector.Snapshot? {
        guard let data = try? Data(contentsOf: fileURL(serverId: serverId)) else { return nil }
        return try? JSONDecoder().decode(HetznerCollector.Snapshot.self, from: data)
    }

    public func save(serverId: String, snapshot: HetznerCollector.Snapshot) throws {
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
