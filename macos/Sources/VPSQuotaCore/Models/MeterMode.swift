import Foundation

/// 服务商统计流量的口径。
///
/// 各家差异很大，且同一家不同套餐也可能不同，所以做成 per-server 配置而不写死：
/// - Vultr 通常按出站计费，对应 `.outbound`
/// - DMIT 分单向（出站）和双向套餐，分别对应 `.outbound` 和 `.sum`
/// - 少数服务商按 max(in, out) 计，对应 `.max`
public enum MeterMode: String, Codable, CaseIterable, Sendable {
    /// 只统计出站流量（tx）
    case outbound
    /// 只统计入站流量（rx）
    case inbound
    /// 进出双向相加
    case sum
    /// 取进、出中较大的一方
    case max

    /// 按本口径把一天的 rx/tx 折算成计费字节数。
    public func billedBytes(rx: Int64, tx: Int64) -> Int64 {
        switch self {
        case .outbound: return tx
        case .inbound: return rx
        case .sum: return rx &+ tx
        case .max: return Swift.max(rx, tx)
        }
    }

    /// 用于设置界面的中文说明。
    public var displayName: String {
        switch self {
        case .outbound: return "仅出站（单向）"
        case .inbound: return "仅入站"
        case .sum: return "进出双向相加"
        case .max: return "取进出较大者"
        }
    }
}
