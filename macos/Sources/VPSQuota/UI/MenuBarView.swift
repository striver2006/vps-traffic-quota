import SwiftUI
import VPSQuotaCore

/// 点击状态栏图标后弹出的主面板。
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            if let fatal = model.fatalError {
                message(fatal, systemImage: "xmark.octagon.fill", color: .red)
            } else if model.config.servers.isEmpty {
                emptyState
            } else {
                ForEach(model.statuses) { status in
                    ServerRowView(status: status) {
                        openWindow(id: WindowID.detail, value: status.server.id)
                    }
                }
            }

            Divider()

            footer
        }
        .frame(width: 320)
        .task { await model.start() }
    }

    private var header: some View {
        HStack {
            Text("VPS 流量")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if model.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            } else if let last = model.lastRefreshAt {
                Text(ByteFormat.relativeTime(last))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("还没有配置服务器")
                .font(.system(size: 12, weight: .medium))
            Text("在设置里添加 Vultr 实例或可 SSH 登录的服务器后即可开始监控。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func message(_ text: String, systemImage: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: systemImage).foregroundStyle(color)
            Text(text)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            menuButton("打开主窗口", systemImage: "macwindow") {
                openWindow(id: WindowID.main)
                NSApp.activate(ignoringOtherApps: true)
            }

            menuButton("立即刷新", systemImage: "arrow.clockwise") {
                Task { await model.refresh() }
            }
            .disabled(model.isRefreshing)

            menuButton("设置…", systemImage: "gearshape") {
                openWindow(id: WindowID.settings)
                NSApp.activate(ignoringOtherApps: true)
            }

            menuButton("退出", systemImage: "power") {
                NSApp.terminate(nil)
            }
        }
        .padding(.vertical, 4)
    }

    private func menuButton(
        _ title: String, systemImage: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .frame(width: 14)
                Text(title)
                Spacer()
            }
            .font(.system(size: 12))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 状态栏上那一小块内容：图标 + 最紧张那台的百分比。
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: iconName)
            if let status = model.mostCritical, let fraction = status.usedFraction {
                Text(ByteFormat.percent(fraction))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
            }
        }
    }

    /// 图标随最紧张那台的严重程度变化，不展开菜单也能察觉异常。
    private var iconName: String {
        if model.fatalError != nil || model.hasAnyError {
            return "exclamationmark.triangle"
        }
        switch model.mostCritical?.severity {
        case .critical: return "chart.bar.fill"
        case .warning: return "chart.bar"
        default: return "chart.bar"
        }
    }
}
