import Foundation

/// 通过 SSH 在服务器上执行 `vnstat` 采集。
///
/// DMIT 没有公开 API，这是唯一可行的自动化途径；同时它也适用于任何没有 API 的服务商。
///
/// 刻意不引入 SSH 库，而是直接调用系统的 `ssh` 可执行文件：
/// - 复用你已有的 `~/.ssh/config`、密钥、跳板机等全部配置，不必在本应用里重新配一遍
/// - 与 Windows 端调用 `ssh.exe` 的行为完全一致
/// - 不引入第三方依赖，也不需要在应用里处理私钥解密
public struct SSHVnstatCollector: Collector {
    /// vnstat 日表默认保留 62 天（配置项 `DayIsKept`），一次取满即可覆盖任何账期。
    private static let dayLimit = 62

    private let sshExecutable: URL
    private let timeout: TimeInterval

    public init(
        sshExecutable: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
        timeout: TimeInterval = 45
    ) {
        self.sshExecutable = sshExecutable
        self.timeout = timeout
    }

    // MARK: - vnstat 的 JSON 结构

    struct VnstatOutput: Decodable {
        struct Interface: Decodable {
            struct Traffic: Decodable {
                struct DayEntry: Decodable {
                    struct DatePart: Decodable {
                        let year: Int
                        let month: Int
                        let day: Int
                    }
                    let date: DatePart
                    let rx: Int64
                    let tx: Int64
                }
                let day: [DayEntry]?
            }
            let name: String
            let traffic: Traffic
        }
        let interfaces: [Interface]
    }

    // MARK: - Collector

    public func fetch(server: ServerConfig, since: Date) async throws -> CollectResult {
        let output = try await runRemote(server: server, command: remoteCommand(server: server))

        // 远端命令的第一行是 `date +%z` 的输出（形如 +0000），其后才是 vnstat 的 JSON。
        guard let braceIndex = output.firstIndex(of: "{") else {
            throw CollectError.noData(
                "服务器「\(server.name)」上的 vnstat 没有返回 JSON。原始输出：\n\(output.prefix(500))"
            )
        }
        let offsetText = output[..<braceIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonText = String(output[braceIndex...])

        let parsed: VnstatOutput
        do {
            parsed = try JSONDecoder().decode(VnstatOutput.self, from: Data(jsonText.utf8))
        } catch {
            throw CollectError.decode("vnstat 输出解析失败：\(error.localizedDescription)")
        }

        // 指定了网卡就按名字挑，没指定就取第一个。
        let wanted = server.interface?.trimmingCharacters(in: .whitespaces)
        let iface: VnstatOutput.Interface?
        if let wanted, !wanted.isEmpty {
            iface = parsed.interfaces.first { $0.name == wanted }
        } else {
            iface = parsed.interfaces.first
        }

        guard let iface else {
            let available = parsed.interfaces.map(\.name).joined(separator: ", ")
            throw CollectError.noData(
                "服务器「\(server.name)」上没有找到网卡「\(wanted ?? "")」。"
                + "vnstat 正在统计的网卡有：\(available.isEmpty ? "（无）" : available)"
            )
        }
        guard let dayEntries = iface.traffic.day, !dayEntries.isEmpty else {
            throw CollectError.noData(
                "网卡「\(iface.name)」还没有可用的日流量数据。vnstat 刚安装时需要运行一段时间才会产生记录。"
            )
        }

        let sinceDay = UTCDay.string(from: since)
        let days = dayEntries
            .map {
                DailyUsage(
                    day: UTCDay.string(year: $0.date.year, month: $0.date.month, day: $0.date.day),
                    rxBytes: $0.rx,
                    txBytes: $0.tx
                )
            }
            .filter { $0.day >= sinceDay }
            .sorted { $0.day < $1.day }

        var warnings: [String] = []
        // vnstat 按服务器本地时区切分自然日，本应用统一按 UTC 记账。
        // 时区不是 UTC 时，账期首尾两天会有几小时的归属偏差 —— 量不大，但要说清楚。
        if !offsetText.isEmpty, offsetText != "+0000" {
            warnings.append(
                "服务器时区为 UTC\(offsetText)，vnstat 的日切分与本应用的 UTC 记账存在数小时偏差。"
                + "如需完全对齐，可在服务器上执行 timedatectl set-timezone UTC。"
            )
        }

        return CollectResult(days: days, reportedQuotaGB: nil, warnings: warnings)
    }

    // MARK: - 连通性诊断

    /// 列出服务器上 vnstat 正在统计的网卡，供设置界面的"测试连接"使用。
    public func listInterfaces(server: ServerConfig) async throws -> [String] {
        let output = try await runRemote(server: server, command: "vnstat --json d 1")
        guard let braceIndex = output.firstIndex(of: "{") else {
            throw CollectError.noData("vnstat 没有返回 JSON。原始输出：\n\(output.prefix(500))")
        }
        let parsed = try JSONDecoder().decode(
            VnstatOutput.self, from: Data(output[braceIndex...].utf8)
        )
        return parsed.interfaces.map(\.name)
    }

    // MARK: - 命令构造

    private func remoteCommand(server: ServerConfig) -> String {
        var vnstat = "vnstat"
        if let iface = server.interface?.trimmingCharacters(in: .whitespaces), !iface.isEmpty {
            vnstat += " -i \(shellQuote(iface))"
        }
        vnstat += " --json d \(Self.dayLimit)"
        // 先输出时区偏移，再输出 JSON —— 一次往返同时拿到数据和校准信息。
        return "date +%z; \(vnstat)"
    }

    private func runRemote(server: ServerConfig, command: String) async throws -> String {
        guard let host = server.sshHost?.trimmingCharacters(in: .whitespaces), !host.isEmpty else {
            throw CollectError.misconfigured("服务器「\(server.name)」未填写 SSH 地址")
        }

        var args: [String] = [
            // 禁止一切交互式提问：缺密钥、host key 变更等情况要立刻失败并报错，
            // 而不是让后台采集永远挂在一个没人看得见的提示上。
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "LogLevel=ERROR",
        ]
        if let port = server.sshPort, port > 0, port != 22 {
            args += ["-p", String(port)]
        }
        if let key = server.sshKeyPath?.trimmingCharacters(in: .whitespaces), !key.isEmpty {
            args += ["-i", (key as NSString).expandingTildeInPath]
        }

        let user = server.sshUser?.trimmingCharacters(in: .whitespaces) ?? ""
        args.append(user.isEmpty ? host : "\(user)@\(host)")
        args.append(command)

        let result = try await ProcessRunner.run(
            executable: sshExecutable, arguments: args, timeout: timeout
        )
        guard result.exitCode == 0 else {
            throw CollectError.commandFailed(
                command: "ssh \(user.isEmpty ? host : "\(user)@\(host)") \(command)",
                exitCode: result.exitCode,
                stderr: result.stderr.isEmpty ? result.stdout : result.stderr
            )
        }
        return result.stdout
    }

    /// 单引号包裹并转义，防止网卡名里的特殊字符被远端 shell 解释。
    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
