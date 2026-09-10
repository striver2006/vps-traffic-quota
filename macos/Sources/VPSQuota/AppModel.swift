import Foundation
import SwiftUI
import VPSQuotaCore

/// 应用在系统里的呈现方式。
///
/// 这是 macOS 独有的呈现偏好，**刻意不放进 config.json** ——
/// 那份配置是两端共用且可互相拷贝的，不该混入平台专属的界面设置。
enum DisplayMode: String, CaseIterable, Sendable {
    case menuBar
    case dock
    case both

    var showsMenuBarItem: Bool { self != .dock }
    var showsDockIcon: Bool { self != .menuBar }

    var displayName: String {
        switch self {
        case .menuBar: return "仅菜单栏"
        case .dock: return "仅 Dock"
        case .both: return "菜单栏 + Dock"
        }
    }
}

/// 界面的唯一状态源。
///
/// 把 actor `TrafficMonitor` 的异步接口包装成主线程上的可观察状态，
/// 同时负责自动刷新的定时器与配置的读写。
@MainActor
@Observable
final class AppModel {
    /// 各服务器的当前状态，按配置顺序。
    private(set) var statuses: [ServerStatus] = []
    private(set) var isRefreshing = false
    private(set) var lastRefreshAt: Date?
    /// 启动阶段的致命错误（例如数据库打不开），非 nil 时界面只显示它。
    private(set) var fatalError: String?

    /// config.json 存在但解析失败。此时**拒绝保存**，免得覆盖掉还能抢救的原文件。
    private(set) var configLoadFailed = false

    /// 钥匙串读不出来（未解锁 / 被拒绝授权 / ACL 失效），与「确实没设置」不是一回事。
    /// 该标志下不会主动删除已存的 Key。
    private(set) var keychainUnavailable = false

    var config: AppConfig {
        didSet { Task { await monitor?.updateConfig(config) } }
    }

    /// 仅用于设置界面回填，不写进配置文件。
    var vultrAPIKey: String = ""

    /// 应用的呈现方式。改动立即生效并持久化。
    var displayMode: DisplayMode {
        didSet {
            guard displayMode != oldValue else { return }
            UserDefaults.standard.set(displayMode.rawValue, forKey: Self.displayModeKey)
            applyActivationPolicy()
        }
    }

    private static let displayModeKey = "displayMode"

    /// 是否开机自启。改动立即生效。
    ///
    /// 状态源是系统（`SMAppService`）而不是本地偏好，所以这里只是给界面绑定用的一份镜像：
    /// 每次显示设置界面前用 `syncLaunchAtLogin()` 重新对齐，否则用户在系统设置里
    /// 关掉之后，这个开关会一直停在"开"的位置。
    var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue, !isApplyingLaunchAtLogin else { return }
            applyLaunchAtLogin()
        }
    }

    /// 登记失败的原因。非 nil 时设置界面会把它连同「打开登录项设置」一起显示出来。
    private(set) var launchAtLoginError: String?

    /// 防止 `applyLaunchAtLogin` 的回滚赋值又触发一轮 didSet。
    private var isApplyingLaunchAtLogin = false

    private var monitor: TrafficMonitor?
    private let configStore = ConfigStore()
    private var refreshTimer: Timer?

    /// 跨 UTC 日时重算用的轻量定时器。
    ///
    /// 账期边界必定落在 UTC 零点，所以"日期变了"是账期可能翻页的充要信号。
    /// 不能指望采集定时器来做这件事：刷新周期可以设成 1440 分钟，
    /// 那样账期都换了大半天，界面还停在上一期的累计值上（验收标准第 5 条）。
    private var rolloverTimer: Timer?

    /// 上一次折算所依据的 UTC 日期。
    private var lastComputedDay = UTCDay.string(from: Date())

    /// `start()` 只该跑一次。它由 `App.bootstrap()` 调用，而不是挂在视图的 `.task` 上 ——
    /// 挂在视图上时菜单栏面板每悬停一次就会重跑一轮采集并重建定时器。
    private var didStart = false

    init() {
        // 默认同时显示菜单栏图标和 Dock 图标。
        // 只用菜单栏是有风险的：菜单栏拥挤时（尤其带刘海的机型）macOS 会静默丢弃状态项，
        // 那样应用就完全没有入口了。宁可多一个 Dock 图标，也不要打不开。
        let saved = UserDefaults.standard.string(forKey: Self.displayModeKey)
        self.displayMode = saved.flatMap(DisplayMode.init(rawValue:)) ?? .both

        // 默认不自启：这是用户该主动做的决定，装完就赖在登录项里不礼貌。
        self.launchAtLogin = LaunchAtLogin.isEnabled

        // 配置读不出来时也要能启动，让用户有机会在设置界面里修好它。
        //
        // 但必须分清「文件不存在」和「文件坏了」：前者是首次启动的正常情况，
        // 后者若也当成空配置，界面会显示"还没有配置服务器"，用户以为要重配，
        // 而任何一次保存都会把那份还能抢救的 config.json 整个覆盖掉。
        // config.json 是用户可备份、可在两端互拷的资产（G2），不能这么对待它。
        do {
            self.config = try configStore.load()   // 文件不存在时返回空配置，不抛
        } catch {
            self.config = AppConfig()
            self.configLoadFailed = true
        }

        // 同理：钥匙串「读到 nil」是确实没设置，「读失败」是另一回事
        // （开机自启时钥匙串还没解锁、用户在授权框上点了拒绝、签名变更导致 ACL 失效）。
        // 两者都吞成空串的话，用户随后开关一次设置窗口，saveConfig() 就会把
        // 钥匙串里那条真实的 Key 当成"用户清空了"而删掉 —— 且没有任何提示。
        do {
            self.vultrAPIKey = try KeychainStore.vultrAPIKey() ?? ""
        } catch {
            self.vultrAPIKey = ""
            self.keychainUnavailable = true
        }

        do {
            let store = try SQLiteStore(path: AppPaths.databaseFile)
            self.monitor = TrafficMonitor(
                store: store, config: config, vultrAPIKey: vultrAPIKey
            )
        } catch {
            self.fatalError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }

        if config.skippedServerCount > 0 {
            self.fatalError = """
                配置文件里有 \(config.skippedServerCount) 台服务器没能读入（缺少 id / name / provider，或字段类型不对），\
                其余服务器照常工作。修好后重启即可：\(configStore.fileURL.path)
                """
        }

        if configLoadFailed {
            self.fatalError = """
                配置文件解析失败，已按空配置启动，且本次不会写入配置文件，以免覆盖它。
                请先备份并修复：\(configStore.fileURL.path)
                """
        }
    }

    /// 把当前的呈现方式应用到 NSApplication。
    ///
    /// Info.plist 里的 LSUIElement 只决定启动时的初始状态，
    /// setActivationPolicy 可以在运行时切换，所以 Dock 图标能随开随关。
    func applyActivationPolicy() {
        NSApp.setActivationPolicy(displayMode.showsDockIcon ? .regular : .accessory)
    }

    // MARK: - 开机自启

    /// 把开关的当前值登记进系统。失败时回滚到系统的真实状态，
    /// 不让开关停在一个并没有生效的位置上。
    private func applyLaunchAtLogin() {
        isApplyingLaunchAtLogin = true
        defer { isApplyingLaunchAtLogin = false }

        do {
            try LaunchAtLogin.setEnabled(launchAtLogin)
            // 登记成功但被系统标为待批准时，实际并没有开起来，得如实告诉用户。
            launchAtLoginError = LaunchAtLogin.requiresApproval
                ? "已登记，但系统设置里这一项还处于关闭状态，需要手动放行。"
                : nil
        } catch {
            launchAtLoginError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            launchAtLogin = LaunchAtLogin.isEnabled
        }
    }

    /// 用系统的真实状态刷新开关。用户可能在系统设置里改过它。
    func syncLaunchAtLogin() {
        isApplyingLaunchAtLogin = true
        defer { isApplyingLaunchAtLogin = false }

        launchAtLogin = LaunchAtLogin.isEnabled
        if !LaunchAtLogin.requiresApproval { launchAtLoginError = nil }
    }

    func openLoginItemsSettings() {
        LaunchAtLogin.openSystemSettings()
    }

    /// 启动流程：先用本地数据把界面填满，再在后台发起真正的采集。
    /// 这样即使网络或 SSH 很慢，打开菜单也能立刻看到上次的数据。
    func start() async {
        guard let monitor, !didStart else { return }
        didStart = true
        statuses = await monitor.statuses()
        scheduleTimer()
        scheduleRolloverCheck()
        await refresh()
    }

    func refresh() async {
        guard let monitor, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        statuses = await monitor.refreshAll()
        lastRefreshAt = Date()
    }

    /// 重新按本地数据折算一遍，不联网。跨过账期重置日时靠它把界面切到新账期。
    func recomputeFromLocal() async {
        guard let monitor else { return }
        statuses = await monitor.statuses()
    }

    /// 每 10 分钟看一眼 UTC 日期是否翻页；翻了就按本地数据重算一次。
    ///
    /// 只读本地库，不发起任何网络请求，所以频率高一点也无所谓。
    /// 账期切换当天用量归零、起始已用量补偿失效，都由这条路径兑现。
    private func scheduleRolloverCheck() {
        rolloverTimer?.invalidate()
        let timer = Timer(timeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.recomputeIfDayChanged() }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        rolloverTimer = timer
    }

    private func recomputeIfDayChanged() async {
        let today = UTCDay.string(from: Date())
        guard today != lastComputedDay else { return }
        lastComputedDay = today
        await recomputeFromLocal()
    }

    // MARK: - 配置

    func saveConfig() {
        // 原文件读不出来时绝不落盘：一次写入就把用户还能抢救的配置盖掉了。
        guard !configLoadFailed else { return }

        do {
            try configStore.save(config)

            // 钥匙串读不出来、用户又没输入新 Key 时，跳过密钥写入。
            // 否则空串会被当成"清空"，把钥匙串里那条真实的 Key 删掉。
            if !(keychainUnavailable && vultrAPIKey.isEmpty) {
                try KeychainStore.setVultrAPIKey(vultrAPIKey.isEmpty ? nil : vultrAPIKey)
            }
        } catch {
            fatalError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return
        }
        Task {
            await monitor?.updateConfig(config)
            await monitor?.setVultrAPIKey(vultrAPIKey.isEmpty ? nil : vultrAPIKey)
            scheduleTimer()
            await refresh()
        }
    }

    /// 测试单台服务器的采集。返回 nil 表示成功。
    func testServer(_ server: ServerConfig) async -> String? {
        guard let monitor else { return "数据库未就绪" }
        // 测试用的是当前编辑中的凭据，先同步过去，否则测的还是旧 Key。
        await monitor.setVultrAPIKey(vultrAPIKey.isEmpty ? nil : vultrAPIKey)
        let error = await monitor.refreshOne(server: server)
        statuses = await monitor.statuses()
        return error
    }

    func history(serverId: String, days: Int) async -> [DailyUsage] {
        guard let monitor else { return [] }
        return await monitor.history(serverId: serverId, days: days)
    }

    // MARK: - 定时刷新

    private func scheduleTimer() {
        refreshTimer?.invalidate()
        let minutes = max(5, config.refreshIntervalMinutes)
        let timer = Timer(timeInterval: Double(minutes) * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        // 采集本来就是低频的，给一分钟容差让系统合并唤醒，省电。
        timer.tolerance = 60
        // 显式加进 .common 模式：默认模式下，菜单打开时定时器会被 tracking run loop 挡住。
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    // MARK: - 汇总

    /// 用量比例最高的一台。比例相同时取列表里靠前的那台。
    ///
    /// 不用 `max(by:)`：它在平局时返回**最后一个**，而 Windows 端的
    /// `OrderByDescending().FirstOrDefault()` 返回第一个。全新的库里各台都是 0.0，
    /// 平局是常态 —— 两端会各自指向不同的服务器，与 G2「配置拷过去表现一致」相悖。
    var mostCritical: ServerStatus? {
        statuses.reduce(into: nil as ServerStatus?) { best, candidate in
            guard let fraction = candidate.usedFraction else { return }
            guard let current = best, let currentFraction = current.usedFraction else {
                best = candidate
                return
            }
            if fraction > currentFraction { best = candidate }
        }
    }

    /// 菜单栏那一小块要反映的那台。
    ///
    /// 优先用设置里指定的服务器；没指定、或指定的那台已经被删掉时，
    /// 回退到用量最紧张的一台 —— 这也是加这个设置之前的行为。
    var menuBarStatus: ServerStatus? {
        if let id = config.menuBarServerId,
           let pinned = statuses.first(where: { $0.server.id == id }) {
            return pinned
        }
        return mostCritical ?? statuses.first
    }

    /// 菜单栏图标旁边的文字：所选服务器本账期还剩多少流量。
    /// 关掉显示、或还没有任何数据时返回 nil，此时菜单栏上只剩图标。
    /// 配额未知时没有"剩余"可言，用短横占位而不是退回百分比。
    var menuBarTitle: String? {
        guard config.menuBarShowsRemaining, let status = menuBarStatus else { return nil }
        guard let remaining = status.remainingGB else { return "—" }
        return ByteFormat.compact(remaining)
    }

    /// 菜单栏文字的三种去向，收成一个值好让设置界面用一个 Picker 表达。
    /// 选「不显示」时会保留原来指定的服务器，改回来不用重选。
    enum MenuBarSelection: Hashable {
        case hidden
        case automatic
        case server(String)
    }

    var menuBarSelection: MenuBarSelection {
        get {
            guard config.menuBarShowsRemaining else { return .hidden }
            if let id = config.menuBarServerId { return .server(id) }
            return .automatic
        }
        set {
            switch newValue {
            case .hidden:
                config.menuBarShowsRemaining = false
            case .automatic:
                config.menuBarShowsRemaining = true
                config.menuBarServerId = nil
            case .server(let id):
                config.menuBarShowsRemaining = true
                config.menuBarServerId = id
            }
        }
    }

    var hasAnyError: Bool {
        statuses.contains { $0.lastError != nil }
    }
}
