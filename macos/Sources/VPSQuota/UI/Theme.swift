import SwiftUI
import VPSQuotaCore

extension ServerStatus.Severity {
    /// 进度条与百分比文字的配色。
    var color: Color {
        switch self {
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        case .unknown: return .secondary
        }
    }
}

/// 用量进度条。
///
/// 不用系统 `ProgressView` 的原因：需要同时表达"已用"和"按当前速度的预测值"两个量，
/// 预测值以一道竖线叠在条上，一眼就能看出会不会冲过配额线。
struct UsageBar: View {
    let fraction: Double?
    let projectedFraction: Double?
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.18))

                if let fraction {
                    Capsule()
                        .fill(color)
                        .frame(width: geo.size.width * min(max(fraction, 0), 1))
                }

                // 预测标记：只在预测值还落在条内、且明显超过当前用量时才画，
                // 否则它会和条的末端糊在一起，反而看不清。
                if let projectedFraction, let fraction,
                   projectedFraction > fraction + 0.02, projectedFraction <= 1 {
                    Rectangle()
                        .fill(color.opacity(0.9))
                        .frame(width: 2)
                        .offset(x: geo.size.width * projectedFraction - 1)
                }
            }
        }
        .frame(height: 6)
    }
}
