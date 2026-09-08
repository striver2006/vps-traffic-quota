import Foundation
import Testing
@testable import VPSQuotaCore

/// config.json 是 macOS 与 Windows 两端共用的格式，用户可以在两台机器之间直接拷贝。
/// 这组测试把字段名和枚举取值钉死 —— 任何一端改了命名，这里都会先红。
@Suite("跨平台配置格式")
struct CrossPlatformConfigTests {

    private func encode(_ config: AppConfig) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(config)
        return try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    @Test("枚举一律编码成小写字符串，与 C# 端的 camelCase 策略一致")
    func enumsEncodeAsLowercaseStrings() throws {
        let config = AppConfig(servers: [
            ServerConfig(id: "a", name: "东京", provider: .vultr,
                         meterMode: .outbound, unitBase: .binary),
            ServerConfig(id: "b", name: "洛杉矶", provider: .ssh,
                         meterMode: .sum, unitBase: .decimal),
        ])
        let json = try encode(config)
        let servers = try #require(json["servers"] as? [[String: Any]])

        #expect(servers[0]["provider"] as? String == "vultr")
        #expect(servers[0]["meterMode"] as? String == "outbound")
        #expect(servers[0]["unitBase"] as? String == "binary")
        #expect(servers[1]["provider"] as? String == "ssh")
        #expect(servers[1]["meterMode"] as? String == "sum")
        #expect(servers[1]["unitBase"] as? String == "decimal")
    }

    @Test("顶层与服务器的字段名与 C# 端逐字对应")
    func fieldNamesMatchWindows() throws {
        let config = AppConfig(refreshIntervalMinutes: 60, servers: [
            ServerConfig(id: "b", name: "洛杉矶", provider: .ssh,
                         quotaGB: 1000, meterMode: .sum, resetDay: 15,
                         unitBase: .binary,
                         sshHost: "1.2.3.4", sshPort: 22, sshUser: "root",
                         sshKeyPath: "~/.ssh/id_ed25519", interface: "eth0"),
        ])
        let json = try encode(config)
        #expect(Set(json.keys) == ["refreshIntervalMinutes", "servers"])

        let server = try #require((json["servers"] as? [[String: Any]])?.first)
        // C# 端的 JsonNamingPolicy.CamelCase 只把首字母小写，
        // 所以 QuotaGB → quotaGB（而不是 quotaGb），这一条最容易写错。
        #expect(Set(server.keys) == [
            "id", "name", "provider", "quotaGB", "meterMode", "resetDay", "unitBase",
            "sshHost", "sshPort", "sshUser", "sshKeyPath", "interface",
        ])
    }

    @Test("能读入 Windows 端写出的配置")
    func decodesWindowsWrittenConfig() throws {
        // 这份 JSON 是按 C# 端 JsonNamingPolicy.CamelCase + 枚举转换器的输出格式手写的
        let json = """
        {
          "refreshIntervalMinutes": 360,
          "servers": [
            {
              "id": "vultr-tokyo",
              "name": "Vultr 东京",
              "provider": "vultr",
              "quotaGB": 0,
              "meterMode": "outbound",
              "resetDay": 1,
              "unitBase": "binary",
              "vultrInstanceId": "cb676a46-66fd-4dfb-b839-443f2e6c0b60"
            },
            {
              "id": "dmit-lax",
              "name": "DMIT 洛杉矶",
              "provider": "ssh",
              "quotaGB": 1000,
              "meterMode": "sum",
              "resetDay": 15,
              "unitBase": "decimal",
              "sshHost": "1.2.3.4",
              "sshPort": 2222,
              "sshUser": "root",
              "sshKeyPath": "~/.ssh/id_ed25519",
              "interface": "eth0"
            }
          ]
        }
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))

        #expect(config.refreshIntervalMinutes == 360)
        #expect(config.servers.count == 2)
        #expect(config.servers[0].provider == .vultr)
        #expect(config.servers[0].meterMode == .outbound)
        #expect(config.servers[0].unitBase == .binary)
        #expect(config.servers[0].quotaGB == 0)
        #expect(config.servers[1].provider == .ssh)
        #expect(config.servers[1].meterMode == .sum)
        #expect(config.servers[1].unitBase == .decimal)
        #expect(config.servers[1].sshPort == 2222)
        #expect(config.servers[1].interface == "eth0")
    }

    @Test("示例配置文件本身能被解析")
    func exampleConfigIsValid() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // VPSQuotaCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // macos
            .deletingLastPathComponent()   // 仓库根目录
            .appendingPathComponent("shared/config.example.json")
        let data = try Data(contentsOf: url)
        let config = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(config.servers.count == 4)
        #expect(config.refreshIntervalMinutes == 60)
    }
}
