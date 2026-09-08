import Foundation

/// 服务商在展示配额时使用的 "GB" 进制。
///
/// 这不是吹毛求疵：1024³ 与 1000³ 相差 7.4%，在用量逼近 90% 时足以造成误判。
/// 各家口径不统一（也几乎没人写在文档里），所以做成 per-server 配置，
/// 由你在首次接入时对照服务商面板显示的数字校准（见 docs/config-reference.md）。
public enum UnitBase: String, Codable, CaseIterable, Sendable {
    /// 1 GB = 1024³ 字节（GiB）。多数使用 vnstat 类工具计量的服务商属于此类，作为默认值。
    case binary
    /// 1 GB = 1000³ 字节
    case decimal

    public var bytesPerGB: Double {
        switch self {
        case .binary: return 1_073_741_824      // 1024³
        case .decimal: return 1_000_000_000     // 1000³
        }
    }

    public var displayName: String {
        switch self {
        case .binary: return "1 GB = 1024³ 字节"
        case .decimal: return "1 GB = 1000³ 字节"
        }
    }
}
