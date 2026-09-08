import Foundation

/// 某台服务器在某一个 UTC 自然日内的流量。
///
/// 这是整个应用的中枢数据结构：两种 Collector 的唯一职责就是产出它的数组，
/// 之后所有计算（存储、账期切分、配额折算）都不再关心数据来自 API 还是 vnstat。
public struct DailyUsage: Codable, Hashable, Sendable {
    /// UTC 日期，格式 YYYY-MM-DD
    public var day: String
    public var rxBytes: Int64
    public var txBytes: Int64

    public init(day: String, rxBytes: Int64, txBytes: Int64) {
        self.day = day
        self.rxBytes = rxBytes
        self.txBytes = txBytes
    }
}
