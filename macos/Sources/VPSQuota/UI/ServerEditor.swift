import SwiftUI
import VPSQuotaCore

/// 单台服务器的编辑表单。
struct ServerEditor: View {
    @Binding var server: ServerConfig
    /// nil = 未测试，"" = 成功，其他 = 错误文本
    let testResult: String?
    let isTesting: Bool
    let onTest: () -> Void

    var body: some View {
        Form {
            Section {
                TextField("名称", text: $server.name)
                LabeledContent("类型", value: server.provider.displayName)
            }

            switch server.provider {
            case .vultr: vultrSection
            case .ssh: sshSection
            }

            quotaSection

            baselineSection

            Section {
                HStack {
                    Button(isTesting ? "测试中…" : "测试连接", action: onTest)
                        .disabled(isTesting)
                    if isTesting {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }
                if let testResult {
                    if testResult.isEmpty {
                        Label("连接成功，已采集到数据", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.system(size: 11))
                    } else {
                        Label {
                            Text(testResult)
                                .font(.system(size: 11))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var vultrSection: some View {
        Section {
            TextField("实例 ID", text: Binding(
                get: { server.vultrInstanceId ?? "" },
                set: { server.vultrInstanceId = $0 }
            ))
            Text("在 Vultr 实例页面的 URL 里，或用命令 vpsquota-cli vultr-instances 列出。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } header: {
            Text("Vultr")
        }
    }

    private var sshSection: some View {
        Section {
            TextField("主机", text: optional(\.sshHost))
            TextField("端口", value: Binding(
                get: { server.sshPort ?? 22 },
                set: { server.sshPort = $0 }
            ), format: .number.grouping(.never))
            TextField("用户名", text: optional(\.sshUser))
            TextField("私钥路径", text: optional(\.sshKeyPath), prompt: Text("~/.ssh/id_ed25519"))
            TextField("网卡", text: optional(\.interface), prompt: Text("留空则用 vnstat 的默认网卡"))
            Text("需要服务器上已安装并启用 vnstat，且本机能免密 SSH 登录（仅支持密钥认证）。详见 github.com/striver2006/vps-traffic-quota 的 docs/setup-dmit.md。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("SSH")
        }
    }

    private var quotaSection: some View {
        Section {
            TextField("月配额（GB）", value: $server.quotaGB, format: .number)
            if server.provider == .vultr {
                Text("填 0 表示自动采用 Vultr API 报告的 allowed_bandwidth。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Picker("计费口径", selection: $server.meterMode) {
                ForEach(MeterMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }

            Picker("GB 进制", selection: $server.unitBase) {
                ForEach(UnitBase.allCases, id: \.self) { base in
                    Text(base.displayName).tag(base)
                }
            }

            Picker("每月重置日", selection: $server.resetDay) {
                ForEach(1...31, id: \.self) { day in
                    Text("\(day) 号").tag(day)
                }
            }
            Text("配额在每月这一天归零。当月没有该日时（例如 31 号遇上 2 月）按当月最后一天处理。计费口径与进制填错会直接导致数字对不上服务商面板，首次配置后请用面板数值校准一次。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("配额")
        }
    }

    /// 当前账期的起点，用于把基准绑定到具体账期。
    private var currentPeriodStart: String {
        BillingPeriod.current(resetDay: server.resetDay).startDay
    }

    /// 本账期开始监控之前已经用掉多少（GB）。读写时自动带上当前账期的起始日，
    /// 这样换账期后旧的补偿值会自动失效。
    private var baselineBinding: Binding<Double> {
        Binding(
            get: {
                guard let b = server.usageBaseline, b.periodStart == currentPeriodStart else { return 0 }
                return b.usedGB
            },
            set: { newValue in
                server.usageBaseline = newValue > 0
                    ? UsageBaseline(periodStart: currentPeriodStart, usedGB: newValue)
                    : nil
            }
        )
    }

    private var baselineSection: some View {
        Section {
            TextField("开始监控前已用（GB）", value: baselineBinding, format: .number)
            Text("在账期中途才装上 vnstat（或数据库被重建过）时，之前的流量本地没有记录，面板会显示得远低于真实值。从服务商面板抄一个当时的已用量填在这里，就能把缺口补上。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LabeledContent("生效账期") {
                Text(currentPeriodStart + " 起")
                    .foregroundStyle(.secondary)
            }
            Text("该补偿值只对上面这个账期有效，下个账期开始后自动清零 —— 否则它会变成凭空多出来的流量。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("起始已用量")
        }
    }

    /// 把可选字符串字段桥接成 TextField 需要的非可选绑定。
    private func optional(_ keyPath: WritableKeyPath<ServerConfig, String?>) -> Binding<String> {
        Binding(
            get: { server[keyPath: keyPath] ?? "" },
            set: { server[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }
}
