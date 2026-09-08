import Foundation

/// 账期内的「起始已用量」基准。
///
/// 存在的理由：vnstat 只能统计它自己开始记录之后的流量。如果在账期中途才装上
/// vnstat（或数据库被重建过），本账期前半段的用量就永远丢失了，面板会显示得远低于真实值。
/// 这时可以从服务商面板抄一个当时的已用量填进来，把缺口补上。
///
/// **绑定到具体账期**是关键设计：`periodStart` 记下这个基准属于哪个账期，
/// 只有当前账期与之吻合时才生效。否则下个账期一到，这个补偿值就会变成凭空多出来的流量。
public struct UsageBaseline: Codable, Hashable, Sendable {
    /// 该基准所属账期的起始日（UTC，YYYY-MM-DD）。
    public var periodStart: String
    /// 账期开始到本地开始采集之间，已经消耗掉的量（GB）。
    public var usedGB: Double

    public init(periodStart: String, usedGB: Double) {
        self.periodStart = periodStart
        self.usedGB = usedGB
    }

    /// 该基准是否适用于给定账期。
    public func applies(to period: BillingPeriod) -> Bool {
        periodStart == period.startDay && usedGB > 0
    }
}
