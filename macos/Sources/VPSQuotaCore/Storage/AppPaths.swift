import Foundation

/// 应用数据目录。
///
/// 与 Windows 端的 `%APPDATA%\VPSTrafficQuota\` 一一对应，文件名保持一致，
/// 方便在两台机器之间直接拷贝 config.json。
public enum AppPaths {
    public static let directoryName = "VPSTrafficQuota"

    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(directoryName, isDirectory: true)
    }

    public static var configFile: URL { directory.appendingPathComponent("config.json") }
    public static var databaseFile: URL { directory.appendingPathComponent("usage.sqlite") }
}
