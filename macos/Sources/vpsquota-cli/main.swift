import Foundation
import VPSQuotaCore

// 诊断用命令行工具。
// 存在的意义：接入真实凭据时，先用它把 API Key / SSH 连通性 / 网卡名 / 计费口径逐项确认，
// 再去动图形界面 —— 否则一个 SSH 报错要透过好几层 UI 才能看见。

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "help"

func printUsage() {
    print("""
    vpsquota-cli —— VPS 流量配额诊断工具

    用法：
      vpsquota-cli status              读取本地数据，显示各服务器当前账期用量（不联网）
      vpsquota-cli refresh             立即采集所有服务器并显示结果
      vpsquota-cli probe               逐台测试连通性，Vultr 列实例、SSH 列网卡
      vpsquota-cli vultr-instances     列出 Vultr 账号下所有实例及其 allowed_bandwidth
      vpsquota-cli set-key <API_KEY>   把 Vultr API Key 写入钥匙串
      vpsquota-cli config-path         打印配置文件与数据库的位置

    配置文件：\(AppPaths.configFile.path)
    """)
}

/// 把一行状态渲染成定宽表格行。
func renderStatus(_ s: ServerStatus) -> String {
    let usage: String
    if let fraction = s.usedFraction {
        let width = 20
        let filled = min(width, max(0, Int((fraction * Double(width)).rounded())))
        let bar = String(repeating: "█", count: filled)
            + String(repeating: "░", count: width - filled)
        usage = "\(bar) \(ByteFormat.percent(fraction))"
    } else {
        usage = String(repeating: "░", count: 20) + " 配额未知"
    }

    let quotaText = s.quotaGB > 0 ? ByteFormat.gb(s.quotaGB) : "未知"
    var line = """
      \(s.server.name)  [\(s.server.provider.displayName) / \(s.server.meterMode.displayName)]
        \(usage)
        已用 \(ByteFormat.gb(s.usedGB)) / \(quotaText)   账期 \(s.period.startDay) → \(s.period.endDayExclusive)（剩 \(s.remainingDays) 天）
    """

    if let projected = s.projectedGB {
        let verdict = s.willExceed ? "  ⚠️ 按此速度将超额" : ""
        line += "\n    按当前速度预计月底用量 \(ByteFormat.gb(projected))\(verdict)"
    }
    if let last = s.lastSuccessAt {
        line += "\n    上次成功采集：\(ByteFormat.relativeTime(last))"
    } else {
        line += "\n    尚未成功采集过"
    }
    for warning in s.warnings {
        line += "\n    ⚠️ \(warning)"
    }
    if let error = s.lastError {
        line += "\n    ❌ \(error)"
    }
    return line
}

func loadMonitor() throws -> (TrafficMonitor, AppConfig) {
    let configStore = ConfigStore()
    let config = try configStore.load()
    guard !config.servers.isEmpty else {
        print("配置里还没有任何服务器。")
        print("请先把 shared/config.example.json 复制到下面这个位置并按实际情况修改：")
        print("  \(AppPaths.configFile.path)")
        exit(1)
    }
    let store = try SQLiteStore(path: AppPaths.databaseFile)
    let key = try? KeychainStore.vultrAPIKey()
    return (TrafficMonitor(store: store, config: config, vultrAPIKey: key), config)
}

do {
    switch command {
    case "config-path":
        print("配置文件：\(AppPaths.configFile.path)")
        print("数据库：  \(AppPaths.databaseFile.path)")

    case "set-key":
        guard arguments.count >= 2, !arguments[1].isEmpty else {
            print("用法：vpsquota-cli set-key <API_KEY>")
            exit(1)
        }
        try KeychainStore.setVultrAPIKey(arguments[1])
        print("✅ Vultr API Key 已写入钥匙串。")

    case "vultr-instances":
        guard let key = try KeychainStore.vultrAPIKey(), !key.isEmpty else {
            print("❌ 钥匙串里还没有 Vultr API Key，请先执行：vpsquota-cli set-key <API_KEY>")
            exit(1)
        }
        let instances = try await VultrCollector(apiKey: key).listInstances()
        guard !instances.isEmpty else {
            print("账号下没有实例。")
            exit(0)
        }
        print("共 \(instances.count) 个实例：\n")
        for i in instances {
            let quota = i.allowedBandwidthGB.map { ByteFormat.gb($0) } ?? "未知"
            print("  \(i.label.isEmpty ? "(无标签)" : i.label)")
            print("    实例 ID：  \(i.id)")
            print("    IP / 区域：\(i.mainIP)  \(i.region)")
            print("    月配额：   \(quota)")
            print("")
        }
        print("把上面的「实例 ID」填进配置文件的 vultrInstanceId 字段。")

    case "status":
        let (monitor, _) = try loadMonitor()
        let statuses = await monitor.statuses()
        print("本地数据（未联网刷新）：\n")
        for s in statuses { print(renderStatus(s)); print("") }

    case "refresh":
        let (monitor, config) = try loadMonitor()
        print("正在采集 \(config.servers.count) 台服务器…\n")
        let statuses = await monitor.refreshAll()
        for s in statuses { print(renderStatus(s)); print("") }
        let failed = statuses.filter { $0.lastError != nil }.count
        if failed > 0 {
            print("有 \(failed) 台采集失败，详见上方的 ❌ 行。")
            exit(1)
        }

    case "probe":
        let (_, config) = try loadMonitor()
        var anyFailure = false

        for server in config.servers {
            print("── \(server.name)（\(server.provider.displayName)）")
            do {
                switch server.provider {
                case .vultr:
                    guard let key = try KeychainStore.vultrAPIKey(), !key.isEmpty else {
                        throw CollectError.misconfigured("钥匙串里没有 Vultr API Key")
                    }
                    let instances = try await VultrCollector(apiKey: key).listInstances()
                    if let match = instances.first(where: { $0.id == server.vultrInstanceId }) {
                        let quota = match.allowedBandwidthGB.map { ByteFormat.gb($0) } ?? "未知"
                        print("   ✅ API 可用，匹配到实例「\(match.label)」，API 报告配额 \(quota)")
                    } else {
                        print("   ❌ API 可用，但账号下没有 ID 为 \(server.vultrInstanceId ?? "(空)") 的实例")
                        print("      账号下现有实例：\(instances.map(\.id).joined(separator: ", "))")
                        anyFailure = true
                    }
                case .ssh:
                    let interfaces = try await SSHVnstatCollector().listInterfaces(server: server)
                    print("   ✅ SSH 可用，vnstat 正在统计的网卡：\(interfaces.joined(separator: ", "))")
                    let configured = server.interface ?? ""
                    if !configured.isEmpty, !interfaces.contains(configured) {
                        print("   ⚠️ 配置里写的网卡「\(configured)」不在上面的列表中")
                        anyFailure = true
                    }
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                print("   ❌ \(message)")
                anyFailure = true
            }
            print("")
        }
        if anyFailure { exit(1) }

    default:
        printUsage()
    }
} catch {
    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    FileHandle.standardError.write(Data("❌ \(message)\n".utf8))
    exit(1)
}
