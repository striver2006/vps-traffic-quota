import AppKit

/// 打开「系统设置 → 控制中心」，供状态项被 ControlCenter 拉黑时引导用户放行。
///
/// 「菜单栏 → 应用程序」那张允许列表就在控制中心面板里，系统没有给它提供
/// `SMAppService.openSystemSettingsLoginItems()` 那样的公开 API，只能走 URL scheme。
/// 这个 scheme 是私有约定，随系统版本可能变，所以打不开时退回打开系统设置本体
/// —— 宁可让用户自己多点两下，也不能静默失败（他正看不见图标、一头雾水）。
enum MenuBarSettingsLink {
    static func open() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension"),
           NSWorkspace.shared.open(url) {
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }
}
