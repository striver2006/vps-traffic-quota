import SwiftUI
import VPSQuotaCore

/// 设置窗口：Vultr 凭据、刷新周期、服务器增删改。
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    @State private var selection: ServerConfig.ID?
    /// 每台服务器的"测试连接"结果。nil 表示没测过，"" 表示成功。
    @State private var testResults: [String: String] = [:]
    @State private var testingId: String?

    var body: some View {
        @Bindable var model = model

        HSplitView {
            serverList
                .frame(minWidth: 200, idealWidth: 220)

            Group {
                if let selection, let index = indexOf(selection) {
                    ServerEditor(
                        server: $model.config.servers[index],
                        testResult: testResults[selection],
                        isTesting: testingId == selection,
                        onTest: { runTest(model.config.servers[index]) }
                    )
                } else {
                    generalSettings
                }
            }
            .frame(minWidth: 380, idealWidth: 420)
        }
        .frame(minHeight: 460)
        .onDisappear { model.saveConfig() }
    }

    // MARK: - 左栏

    private var serverList: some View {
        @Bindable var model = model

        return VStack(spacing: 0) {
            List(selection: $selection) {
                Section("通用") {
                    Label("常规设置", systemImage: "gearshape")
                        .tag(String?.none)
                }
                Section("服务器") {
                    ForEach(model.config.servers) { server in
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(server.name.isEmpty ? "未命名" : server.name)
                                Text(server.provider.displayName)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: server.provider == .vultr ? "cloud" : "terminal")
                        }
                        .tag(Optional(server.id))
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            HStack(spacing: 2) {
                Menu {
                    Button("Vultr 实例") { addServer(provider: .vultr) }
                    Button("SSH + vnstat（DMIT 等）") { addServer(provider: .ssh) }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 28)

                Button {
                    removeSelected()
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(selection == nil)

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
    }

    // MARK: - 通用设置

    private var generalSettings: some View {
        @Bindable var model = model

        return Form {
            Section {
                SecureField("Vultr API Key", text: $model.vultrAPIKey)
                    .textFieldStyle(.roundedBorder)
                Text("在 Vultr 后台 Account → API 页面创建。注意该页面默认启用访问控制，需要把你当前的出口 IP 加入允许列表，否则会返回 403。密钥保存在系统钥匙串，不写入配置文件。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Vultr 凭据")
            }

            Section {
                Picker("自动刷新", selection: $model.config.refreshIntervalMinutes) {
                    Text("每 15 分钟").tag(15)
                    Text("每小时").tag(60)
                    Text("每 6 小时").tag(360)
                    Text("每天").tag(1440)
                }
                Text("Vultr 的带宽数据本身是周期性刷新的，并非实时，刷新过于频繁没有意义。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("刷新")
            }

            Section {
                Picker("显示方式", selection: $model.displayMode) {
                    ForEach(DisplayMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Text("菜单栏拥挤时（尤其带刘海的机型）macOS 会静默丢弃放不下的状态项，图标就会消失。保留 Dock 图标可以确保任何情况下都能打开主窗口；也可以在终端执行 open -a VPSQuota 唤出。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("呈现方式")
            }

            Section {
                LabeledContent("配置文件") {
                    Button(AppPaths.configFile.path) {
                        NSWorkspace.shared.activateFileViewerSelecting([AppPaths.configFile])
                    }
                    .buttonStyle(.link)
                    .lineLimit(1)
                    .truncationMode(.head)
                }
            } header: {
                Text("位置")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: -

    private func indexOf(_ id: String) -> Int? {
        model.config.servers.firstIndex { $0.id == id }
    }

    private func addServer(provider: ProviderKind) {
        @Bindable var model = model
        let id = "\(provider.rawValue)-\(UUID().uuidString.prefix(8).lowercased())"
        let server = ServerConfig(
            id: id,
            name: provider == .vultr ? "新的 Vultr 实例" : "新的服务器",
            provider: provider,
            quotaGB: provider == .vultr ? 0 : 1000,
            meterMode: provider == .vultr ? .outbound : .sum,
            resetDay: 1,
            sshPort: provider == .ssh ? 22 : nil,
            sshUser: provider == .ssh ? "root" : nil
        )
        model.config.servers.append(server)
        selection = id
    }

    private func removeSelected() {
        @Bindable var model = model
        guard let selection, let index = indexOf(selection) else { return }
        model.config.servers.remove(at: index)
        self.selection = nil
    }

    private func runTest(_ server: ServerConfig) {
        testingId = server.id
        Task {
            // 测试前先落盘，否则测的是编辑前的旧值。
            model.saveConfig()
            let error = await model.testServer(server)
            testResults[server.id] = error ?? ""
            testingId = nil
        }
    }
}
