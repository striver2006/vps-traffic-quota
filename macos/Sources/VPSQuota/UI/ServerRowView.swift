import SwiftUI
import VPSQuotaCore

/// 菜单里的单台服务器。
struct ServerRowView: View {
    let status: ServerStatus
    let onSelect: () -> Void

    private var quotaText: String {
        status.quotaGB > 0 ? ByteFormat.gb(status.quotaGB) : "配额未知"
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
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
