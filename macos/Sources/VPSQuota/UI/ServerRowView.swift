import SwiftUI
import VPSQuotaCore

/// 菜单里的单台服务器。
struct ServerRowView: View {
    let status: ServerStatus
    /// 菜单栏那块数字说的就是这一台。只在浮动面板里标出来。
    var isPinnedToMenuBar: Bool = false
    let onSelect: () -> Void

    private var quotaText: String {
        status.quotaGB > 0 ? ByteFormat.gb(status.quotaGB) : "配额未知"
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    if isPinnedToMenuBar {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .help("菜单栏显示的就是这一台")
                    }
                    Text(status.server.name)
                        .font(.system(size: 13, weight: .medium))
                    if status.lastError != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.system(size: 10))
                    }
                    Spacer()
                    if let fraction = status.usedFraction {
                        Text(ByteFormat.percent(fraction))
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(status.severity.color)
                    }
                }

                UsageBar(
                    fraction: status.usedFraction,
                    projectedFraction: status.quotaGB > 0
                        ? status.projectedGB.map { $0 / status.quotaGB }
                        : nil,
                    color: status.severity.color
                )

                HStack(spacing: 4) {
                    Text("\(ByteFormat.gb(status.usedGB)) / \(quotaText)")
                    if let remaining = status.remainingGB {
                        Text("·")
                        Text("剩余 \(ByteFormat.gb(remaining))")
                    }
                    Text("·")
                    Text("剩 \(status.remainingDays) 天")
                    if status.willExceed {
                        Text("·")
                        Text("将超额")
                            .foregroundStyle(.red)
                    }
                }
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)

                if let error = status.lastError {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
