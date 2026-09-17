import Foundation

/// 统一管理应用版本与项目元信息。
public enum AppInfo: Sendable {
    /// 默认或编译回退版本号。
    public static let fallbackVersion = "1.0.2"

    /// 项目仓库主页。
    public static let projectURL = URL(string: "https://github.com/striver2006/vps-traffic-quota")!

    /// Releases 发布页面（用于检查与比对最新版本）。
    public static let releasesURL = URL(string: "https://github.com/striver2006/vps-traffic-quota/releases")!

    /// 运行时版本号。优先从主 Bundle 读取，读取不到时回退到 fallbackVersion。
    public static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? fallbackVersion
    }
}
