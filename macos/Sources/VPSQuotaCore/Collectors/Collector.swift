import Foundation

/// 采集结果。
///
/// 除了日流量，Vultr 还能顺带报告实例的 `allowed_bandwidth`，
/// 用户没手填配额时就用它，所以这里一并带出来。
public struct CollectResult: Sendable {
    public var days: [DailyUsage]
    /// 上游报告的月配额（GB）。SSH 采集拿不到，恒为 nil。
    public var reportedQuotaGB: Double?
    /// 采集成功但有值得提醒的情况（例如服务器时区不是 UTC，导致日切分有偏差）。
    public var warnings: [String]

    public init(days: [DailyUsage], reportedQuotaGB: Double? = nil, warnings: [String] = []) {
        self.days = days
        self.reportedQuotaGB = reportedQuotaGB
        self.warnings = warnings
    }
}

/// 采集器：把某个服务商的数据统一成按天的 rx/tx 序列。
///
/// 这是全应用唯一需要按服务商分别实现的部分。往下（存储、账期折算、UI）
/// 都不再区分数据来源，新增服务商只要多写一个实现。
public protocol Collector: Sendable {
    /// - Parameter since: 需要覆盖到的最早 UTC 日期（含）。实现可以返回更多天，
    ///   多出的部分会在账期折算时被过滤掉。
    func fetch(server: ServerConfig, since: Date) async throws -> CollectResult
}

public enum CollectError: LocalizedError {
    case misconfigured(String)
    case http(status: Int, body: String)
    case decode(String)
    case commandFailed(command: String, exitCode: Int32, stderr: String)
    case noData(String)

    public var errorDescription: String? {
        switch self {
        case .misconfigured(let m):
            return "配置不完整：\(m)"
        case .http(let status, let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = trimmed.isEmpty ? "" : "：\(trimmed.prefix(300))"
            return "HTTP \(status)\(detail)"
        case .decode(let m):
            return "无法解析返回数据：\(m)"
        case .commandFailed(let command, let exitCode, let stderr):
            // 原样透出 stderr —— SSH 的报错（Permission denied / Host key 变更 /
            // command not found）是排查问题的全部线索，绝不能吞掉。
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "命令执行失败（退出码 \(exitCode)）：\(command)\n\(trimmed)"
        case .noData(let m):
            return m
        }
    }
}
