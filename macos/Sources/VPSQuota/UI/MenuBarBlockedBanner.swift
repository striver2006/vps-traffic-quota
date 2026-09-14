import SwiftUI

/// 「菜单栏图标被系统隐藏」的告知横幅。
///
/// 被 ControlCenter 拉黑时图标本身就看不见，提示必须出现在菜单栏之外，
/// 所以主窗口与设置界面各挂一条。这是**持续状态**而不是一次性事件，
/// 所以用常驻 UI 而不是系统通知：用户三天后打开应用也该看得到，
/// 放行之后它会自己消失（见 `StatusItemController.exitBlockedBySystem`）。
///
/// 文案同时覆盖两种场景：应用无法可靠区分自己是被哪一条记录牵连的
/// —— 用户自己关掉了本应用那行，还是从 IDE 集成终端启动因而被归到 IDE 名下。
struct MenuBarBlockedBanner: View {
    /// 设置界面里空间紧，只留一句话
    let compact: Bool
    let openSettings: () -> Void

    private var detail: String {
        compact
            ? "到「系统设置 › 控制中心 › 菜单栏 › 应用程序」把「VPS 流量」那一行打开。"
            : """
              系统的控制中心不让这个菜单栏图标显示，应用本身在正常运行、流量也在照常采集。
              到「系统设置 › 控制中心 › 菜单栏 › 应用程序」把「VPS 流量」那一行打开即可；\
              如果这个进程是从 VS Code 等 IDE 的集成终端里启动的，要打开的是那个 IDE 那一行。\
              放行后图标会自动回来，不用重启应用。
              """
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("菜单栏图标被系统隐藏")
                    .font(.system(size: 12, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            // 两种 buttonStyle 是不同类型，没法写成三元
            if compact {
                Button("打开菜单栏设置", action: openSettings)
                    .buttonStyle(.link)
            } else {
                Button("打开菜单栏设置", action: openSettings)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12))
    }
}
