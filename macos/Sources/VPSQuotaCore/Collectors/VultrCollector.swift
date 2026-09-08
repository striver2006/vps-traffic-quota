import Foundation

/// 通过 Vultr 官方 REST API v2 采集。
///
/// 用到两个端点：
/// - `GET /v2/instances`            —— 取 `allowed_bandwidth`（GB）作为配额来源
/// - `GET /v2/instances/{id}/bandwidth` —— 取按天的 `incoming_bytes` / `outgoing_bytes`
///
/// 注意：Vultr 官方明确说明带宽数据是**周期性刷新**的，不是实时值，
/// 因此没必要把刷新周期设得太短。日期键是 UTC，与本应用的存储口径一致，无需换算。
public struct VultrCollector: Collector {
    private let apiKey: String
    private let session: URLSession
    private let baseURL: URL

    public init(
        apiKey: String,
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://api.vultr.com/v2")!
    ) {
        self.apiKey = apiKey
        self.session = session
        self.baseURL = baseURL
    }

    // MARK: - 响应模型

    struct InstancesResponse: Decodable {
        struct Instance: Decodable {
            let id: String
            let label: String?
            let mainIP: String?
            let region: String?
            let allowedBandwidth: Double?

            enum CodingKeys: String, CodingKey {
                case id, label, region
                case mainIP = "main_ip"
                case allowedBandwidth = "allowed_bandwidth"
            }
        }
        let instances: [Instance]
    }

    struct BandwidthResponse: Decodable {
        struct Entry: Decodable {
            let incomingBytes: Int64
            let outgoingBytes: Int64

            enum CodingKeys: String, CodingKey {
                case incomingBytes = "incoming_bytes"
                case outgoingBytes = "outgoing_bytes"
            }
        }
        /// 键是 `YYYY-MM-DD`（UTC）
        let bandwidth: [String: Entry]
    }

    /// 供设置界面"测试连接"和 CLI probe 使用：列出账号下所有实例。
    public struct InstanceSummary: Sendable, Identifiable {
        public let id: String
        public let label: String
        public let mainIP: String
        public let region: String
        public let allowedBandwidthGB: Double?
    }

    public func listInstances() async throws -> [InstanceSummary] {
        let response: InstancesResponse = try await get(path: "instances?per_page=500")
        return response.instances.map {
            InstanceSummary(
                id: $0.id,
                label: $0.label ?? "",
                mainIP: $0.mainIP ?? "",
                region: $0.region ?? "",
                allowedBandwidthGB: $0.allowedBandwidth
            )
        }
    }

    // MARK: - Collector

    public func fetch(server: ServerConfig, since: Date) async throws -> CollectResult {
        guard let instanceId = server.vultrInstanceId, !instanceId.isEmpty else {
            throw CollectError.misconfigured("服务器「\(server.name)」未填写 Vultr 实例 ID")
        }

        // 配额：只在用户没手填时才去问 API，省一次请求。
        var reportedQuota: Double?
        if server.quotaGB <= 0 {
            let instances = try await listInstances()
            reportedQuota = instances.first { $0.id == instanceId }?.allowedBandwidthGB
        }

        let response: BandwidthResponse = try await get(path: "instances/\(instanceId)/bandwidth")
        let sinceDay = UTCDay.string(from: since)

        let days = response.bandwidth
            .filter { $0.key >= sinceDay }
            .map { DailyUsage(day: $0.key, rxBytes: $0.value.incomingBytes, txBytes: $0.value.outgoingBytes) }
            .sorted { $0.day < $1.day }

        return CollectResult(days: days, reportedQuotaGB: reportedQuota)
    }

    // MARK: - HTTP

    private func get<T: Decodable>(path: String) async throws -> T {
        guard !apiKey.isEmpty else {
            throw CollectError.misconfigured("尚未设置 Vultr API Key")
        }
        guard let url = URL(string: path, relativeTo: baseURL.appendingPathComponent("")) else {
            throw CollectError.misconfigured("无效的请求路径：\(path)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CollectError.decode("非 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            var body = String(data: data, encoding: .utf8) ?? ""
            // 401/403 十有八九是 API Key 写错，或者出口 IP 没加进 Vultr 的访问白名单。
            if http.statusCode == 401 || http.statusCode == 403 {
                body += "\n提示：请确认 API Key 正确，且已在 Vultr 后台的 API 页面把你当前的出口 IP 加入允许访问的地址段。"
            }
            throw CollectError.http(status: http.statusCode, body: body)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw CollectError.decode(error.localizedDescription)
        }
    }
}
