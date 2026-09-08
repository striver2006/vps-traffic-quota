import AppKit
import SwiftUI
import VPSQuotaCore

enum WindowID {
    static let main = "main"
    static let settings = "settings"
    static let detail = "detail"
}

/// 处理「应用已在运行时被再次打开」的情况。
///
/// 这是 `.accessory` 应用的关键一环：点 Dock 图标、或在终端执行
/// `open -a VPSQuota`，系统发的都是 reopen 事件而不是重新启动。
/// 不处理它的话，一个没有可见窗口的菜单栏应用会毫无反应 ——
/// 而当菜单栏图标被刘海挤掉时，这恰恰是唯一的入口。
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 由 `VPSQuotaApp` 在启动时注入，用于打开主窗口。
    var openMainWindow: (() -> Void)?

    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows: Bool
    ) -> Bool {
        if !hasVisibleWindows { openMainWindow?() }
        return true
    }
}

@main
struct VPSQuotaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    @Environment(\.openWindow) private var openWindowFromEnvironment

    var body: some Scene {
        Window("VPS 流量", id: WindowID.main) {
            MainWindowView()
                .environment(model)
                .onAppear { bootstrap() }
        }
        .defaultSize(width: 900, height: 600)
        .commands {
            CommandGroup(replacing: .newItem) {}   // 主窗口是单例，不提供"新建"

            // 默认的「帮助」菜单指向一本并不存在的帮助书，点了只会弹
            // “Help isn't available for …”。换成两个真正有用的入口。
            CommandGroup(replacing: .help) {
                Button("使用说明") {
                    // 打包时若有 pandoc 就渲染成 HTML（表格和代码块才能正常呈现），
                    // 没有则退回原始 Markdown —— 两种情况都要能打开。
                    let bundle = Bundle.main
                    if let url = bundle.url(forResource: "README", withExtension: "html")
                        ?? bundle.url(forResource: "README", withExtension: "md") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("打开配置文件夹") {
                    NSWorkspace.shared.open(AppPaths.directory)
                }
            }
        }

        // isInserted 让用户能彻底关掉菜单栏项（选「仅 Dock」时）。
        MenuBarExtra(isInserted: Binding(
            get: { model.displayMode.showsMenuBarItem },
            set: { _ in }   // 只受设置驱动，不允许从别处改
        )) {
            MenuBarView()
                .environment(model)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        // .window 而非默认的 .menu：需要在弹出面板里放进度条、图表这类自定义视图。
        .menuBarExtraStyle(.window)

        Window("设置", id: WindowID.settings) {
            SettingsView()
                .environment(model)
        }
        .windowResizability(.contentSize)
        // SwiftUI 默认会在启动时把每个 Window 场景都建出来，
        // 设置窗口每次开机都自己弹出来显然不对，这里显式抑制。
        // 主窗口则保持默认行为：它是菜单栏图标被挤掉时的兜底入口，
        // 启动时出现一次也顺带保证了 bootstrap() 一定会跑到。
        .defaultLaunchBehavior(.suppressed)

        WindowGroup(id: WindowID.detail, for: String.self) { $serverId in
            ServerDetailView(serverId: serverId ?? "")
                .environment(model)
        }
        .windowResizability(.contentSize)
    }

    /// 主窗口首次出现时接好 Dock / `open -a` 的重新打开路径，并应用呈现方式。
    private func bootstrap() {
        model.applyActivationPolicy()

        let open = openWindowFromEnvironment
        appDelegate.openMainWindow = {
            open(id: WindowID.main)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
