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
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    /// 由 `VPSQuotaApp` 在启动时注入，用于打开主窗口。
    var openMainWindow: (() -> Void)?

    /// 由 `VPSQuotaApp` 在启动时注入，用于关掉主窗口。
    var closeMainWindow: (() -> Void)?

    /// 菜单栏常驻项。必须由这里强引用着，否则状态项会随控制器一起被释放。
    var statusItem: StatusItemController?

    /// 这次是被系统当作登录项拉起来的，而不是用户自己双击打开的。
    private(set) var launchedAtLogin = false

    /// 开机自启时不要把主窗口糊到用户脸上 —— 登录那一刻他要的是它安静地待在菜单栏里。
    func applicationDidFinishLaunching(_ notification: Notification) {
        let isDefaultLaunch =
            notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
        launchedAtLogin = !isDefaultLaunch

        // 无论何种方式启动（开机自启、双击、命令行），常驻生命周期都在这里完成装配：
        // 1. 设置应用激活策略（是否显示 Dock 图标）
        model.applyActivationPolicy()

        // 2. 状态项常驻菜单栏
        if statusItem == nil {
            statusItem = StatusItemController(model: model)
        }

        // 3. 启动后台监控与数据轮询
        Task { await model.start() }

        // 4. 开机自启时不要把主窗口糊到用户脸上：如果窗口被建出来了就由这里关掉
        if launchedAtLogin {
            DispatchQueue.main.async { [weak self] in self?.closeMainWindow?() }
        }
    }

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

    @Environment(\.openWindow) private var openWindowFromEnvironment
    @Environment(\.dismissWindow) private var dismissWindowFromEnvironment

    var body: some Scene {
        let _ = configureDelegates()

        Window("VPS 流量", id: WindowID.main) {
            MainWindowView()
                .environment(appDelegate.model)
                .onAppear {
                    if appDelegate.launchedAtLogin {
                        dismissWindowFromEnvironment(id: WindowID.main)
                    }
                }
        }
        .defaultSize(width: 900, height: 600)
        .commands {
            CommandGroup(replacing: .newItem) {}   // 主窗口是单例，不提供"新建"

            CommandGroup(replacing: .appInfo) {
                Button("关于 VPS 流量") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .applicationVersion: AppInfo.version
                    ])
                }
            }

            // 默认的「帮助」菜单指向一本并不存在的帮助书，点了只会弹
            // “Help isn't available for …”。换成真正有用的入口。
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
                Button("检查最新版本…") {
                    NSWorkspace.shared.open(AppInfo.releasesURL)
                }
                Button("打开配置文件夹") {
                    NSWorkspace.shared.open(AppPaths.directory)
                }
            }
        }

        // 菜单栏项不在这里声明：它需要响应鼠标悬停，而 MenuBarExtra 只认点击。
        // 见 StatusItemController —— 由 AppDelegate 在启动时装上。

        Window("设置", id: WindowID.settings) {
            SettingsView()
                .environment(appDelegate.model)
        }
        .windowResizability(.contentSize)
        // SwiftUI 默认会在启动时把每个 Window 场景都建出来，
        // 设置窗口每次开机都自己弹出来显然不对，这里显式抑制。
        .defaultLaunchBehavior(.suppressed)

        WindowGroup(id: WindowID.detail, for: String.self) { $serverId in
            ServerDetailView(serverId: serverId ?? "")
                .environment(appDelegate.model)
        }
        .windowResizability(.contentSize)
    }

    private func configureDelegates() {
        let open = openWindowFromEnvironment
        appDelegate.openMainWindow = {
            open(id: WindowID.main)
            NSApp.activate(ignoringOtherApps: true)
        }

        let dismiss = dismissWindowFromEnvironment
        appDelegate.closeMainWindow = { dismiss(id: WindowID.main) }
    }
}
