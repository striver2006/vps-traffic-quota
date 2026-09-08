import Foundation

/// 读写 `~/Library/Application Support/VPSTrafficQuota/config.json`。
public struct ConfigStore: Sendable {
    private let url: URL

    public init(url: URL = AppPaths.configFile) {
        self.url = url
    }

    public var fileURL: URL { url }

    public var exists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// 读取配置。文件不存在时返回空配置而不是报错 —— 首次启动就是这种情况，
    /// 应用要能正常起来并引导用户去设置界面。
    public func load() throws -> AppConfig {
        guard exists else { return AppConfig() }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(AppConfig.self, from: data)
    }

    public func save(_ config: AppConfig) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(config)
        // 原子写入，避免写到一半崩溃留下半份配置。
        try data.write(to: url, options: .atomic)
    }
}
