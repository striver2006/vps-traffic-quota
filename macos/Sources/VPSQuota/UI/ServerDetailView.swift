import Charts
import SwiftUI
import VPSQuotaCore

/// 单台服务器的详情窗口：账期概览 + 每日用量柱状图 + 累计折线。
struct ServerDetailView: View {
    let serverId: String
    @Environment(AppModel.self) private var model

    @State private var history: [DailyUsage] = []

    private var status: ServerStatus? {
        model.statuses.first { $0.server.id == serverId }
    }

    var body: some View {
        Group {
            if let status {
                content(status)
            } else {
                ContentUnavailableView(
                    "找不到这台服务器",
                    systemImage: "questionmark.folder",
                    description: Text("它可能已经在设置里被删除了。")
                )
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .navigationTitle(status?.server.name ?? "详情")
        .task(id: serverId) {
            history = await model.history(serverId: serverId, days: 60)
        }
    }

    private func content(_ status: ServerStatus) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            summary(status)
            Divider()
            charts(status)
        }
        .padding(20)
    }

    // MARK: - 概览

    private func summary(_ status: ServerStatus) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(ByteFormat.gb(status.usedGB))
                    .font(.system(size: 30, weight: .semibold).monospacedDigit())
                    .foregroundStyle(status.severity.color)
                if status.quotaGB > 0 {
                    Text("/ \(ByteFormat.gb(status.quotaGB))")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let fraction = status.usedFraction {
                    Text(ByteFormat.percent(fraction))
                        .font(.system(size: 22, weight: .medium).monospacedDigit())
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

            HStack(spacing: 22) {
                metric("账期", "\(status.period.startDay) → \(status.period.endDayExclusive)")
                metric("剩余", "\(status.remainingDays) 天")
                if let remaining = status.remainingGB {
                    metric("剩余流量", ByteFormat.gb(remaining))
                }
                if let projected = status.projectedGB {
                    metric(
                        "预计月底",
                        ByteFormat.gb(projected),
                        highlight: status.willExceed
                    )
                }
            }

            metric("计费口径", "\(status.server.meterMode.displayName) · \(status.server.unitBase.displayName)")

            ForEach(status.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = status.lastError {
                Label {
                    Text(error).textSelection(.enabled)
                } icon: {
                    Image(systemName: "xmark.circle.fill")
                }
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func metric(_ label: String, _ value: String, highlight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(highlight ? .red : .primary)
        }
    }

    // MARK: - 图表

    /// 图表用的一天：按计费口径折算后的当日用量与账期内累计用量。
    private struct ChartPoint: Identifiable {
        let id: String
        let date: Date
        let dailyGB: Double
        let cumulativeGB: Double
    }

    private func points(_ status: ServerStatus) -> [ChartPoint] {
        var cumulative = 0.0
        return status.days.compactMap { day in
            guard let date = UTCDay.date(from: day.day) else { return nil }
            let bytes = status.server.meterMode.billedBytes(rx: day.rxBytes, tx: day.txBytes)
            let gb = Double(bytes) / status.server.unitBase.bytesPerGB
            cumulative += gb
            return ChartPoint(id: day.day, date: date, dailyGB: gb, cumulativeGB: cumulative)
        }
    }

    @ViewBuilder
    private func charts(_ status: ServerStatus) -> some View {
        let data = points(status)

        if data.isEmpty {
            ContentUnavailableView(
                "本账期还没有数据",
                systemImage: "chart.bar",
                description: Text("刷新一次，或检查该服务器的采集是否报错。")
            )
            .frame(maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                Text("每日用量")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Chart(data) { point in
                    BarMark(
                        x: .value("日期", point.date, unit: .day),
                        y: .value("用量", point.dailyGB)
                    )
                    .foregroundStyle(status.severity.color.opacity(0.75))
                }
                .chartYAxisLabel("GB")
                .frame(height: 130)

                Text("账期累计")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Chart {
                    ForEach(data) { point in
                        LineMark(
                            x: .value("日期", point.date, unit: .day),
                            y: .value("累计", point.cumulativeGB)
                        )
                        .foregroundStyle(status.severity.color)
                        AreaMark(
                            x: .value("日期", point.date, unit: .day),
                            y: .value("累计", point.cumulativeGB)
                        )
                        .foregroundStyle(status.severity.color.opacity(0.12))
                    }
                    // 配额线：累计折线一旦顶上去就说明用完了，比看数字直观。
                    if status.quotaGB > 0 {
                        RuleMark(y: .value("配额", status.quotaGB))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .foregroundStyle(.red.opacity(0.7))
                            .annotation(position: .top, alignment: .leading) {
                                Text("配额 \(ByteFormat.gb(status.quotaGB))")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.red)
                            }
                    }
                }
                .chartYAxisLabel("GB")
                .frame(height: 150)
            }
        }
    }
}
