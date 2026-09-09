import AppKit
import Foundation
import ServiceManagement

/// 开机自启：把应用登记进系统的「登录项」。
///
/// 用 `SMAppService.mainApp`（macOS 13+）而不是往 `~/Library/LaunchAgents` 里塞 plist ——
/// 后者在现代 macOS 上会被「登录项」界面标成来路不明的后台项目，也需要自己管理 plist 的
/// 生命周期。`SMAppService` 登记的是 bundle 本身，用户在系统设置里看到的就是这个应用。
///
/// 真正的状态由系统持有，这里不做任何本地缓存：用户随时可能在系统设置里把它关掉，
/// 存一份自己的副本只会和系统对不上。
enum LaunchAtLogin {
    /// 当前是否已启用。`.requiresApproval` 不算启用 —— 登记还在，但被用户在系统设置里关了。
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// 已登记但被用户在「系统设置 → 通用 → 登录项」里手动关掉。
    /// 这种情况只能引导用户去系统设置里放行，应用自己 register 一万次也没用。
    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            // 已经是 .enabled 时重复 register 会抛「已存在」的错，先挡掉。
            guard service.status != .enabled else { return }
            try service.register()
        } else {
            // 同理，从没登记过时 unregister 也会抛错。
            guard service.status != .notRegistered else { return }
            try service.unregister()
        }
    }

    /// 打开「系统设置 → 通用 → 登录项」，供被系统拦下时引导用户放行。
    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
