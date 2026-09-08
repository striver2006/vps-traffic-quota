import SwiftUI
import VPSQuotaCore

/// 主窗口：左侧服务器列表，右侧选中项的详情与趋势图。
///
/// 菜单栏图标可能因为菜单栏拥挤（尤其带刘海的机型）被 macOS 静默丢弃，
/// 那时这个窗口就是应用唯一的入口 —— 可以通过 Dock 图标、
/// 或在终端执行 `open -a VPSQuota` 打开。
struct MainWindowView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    @State private var selection: String?

    private var selectedStatus: ServerStatus? {
        model.statuses.first { $0.server.id == selection }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 340)
        } detail: {
            detail
        }
        .frame(minWidth: 820, minHeight: 520)
        .navigationTitle("VPS 流量")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(model.isRefreshing)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    openWindow(id: WindowID.settings)
                } label: {
                    Label("设置", systemImage: "gearshape")
                }
            }
        }
        .task {
            await model.start()
            // 默认选中最紧张的那台，打开就直奔重点。
            if selection == nil {
                selection = model.mostCritical?.server.id ?? model.statuses.first?.server.id
            }
        }
    }

    private var sidebar: some View {
        List(model.statuses, selection: $selection) { status in
            ServerRowView(status: status) {
                selection = status.server.id
            }
            .tag(status.server.id)
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 6) {
                if model.isRefreshing {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                    Text("正在采集…")
                } else if let last = model.lastRefreshAt {
                    Text("上次刷新 \(ByteFormat.relativeTime(last))")
                } else {
                    Text("尚未刷新")
                }
                Spacer()
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let fatal = model.fatalError {
            ContentUnavailableView {
                Label("无法启动", systemImage: "xmark.octagon.fill")
            } description: {
                Text(fatal)
            }
        } else if model.config.servers.isEmpty {
            ContentUnavailableView {
                Label("还没有配置服务器", systemImage: "server.rack")
            } description: {
                Text("添加 Vultr 实例或可 SSH 登录的服务器后即可开始监控。")
            } actions: {
                Button("打开设置") { openWindow(id: WindowID.settings) }
            }
        } else if let status = selectedStatus {
            ScrollView {
                ServerDetailContent(status: status)
            }
        } else {
            ContentUnavailableView(
                "选择一台服务器",
                systemImage: "sidebar.left",
                description: Text("在左侧选择要查看的服务器。")
            )
        }
    }
}
