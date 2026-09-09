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

    private var monitor: TrafficMonitor?
    private let configStore = ConfigStore()
    private var refreshTimer: Timer?

    init() {
        // 默认同时显示菜单栏图标和 Dock 图标。
        // 只用菜单栏是有风险的：菜单栏拥挤时（尤其带刘海的机型）macOS 会静默丢弃状态项，
        // 那样应用就完全没有入口了。宁可多一个 Dock 图标，也不要打不开。
        let saved = UserDefaults.standard.string(forKey: Self.displayModeKey)
        self.displayMode = saved.flatMap(DisplayMode.init(rawValue:)) ?? .both

        // 配置读不出来时也要能启动，让用户有机会在设置界面里修好它。
        self.config = (try? configStore.load()) ?? AppConfig()
        self.vultrAPIKey = (try? KeychainStore.vultrAPIKey()) ?? ""

        do {
            let store = try SQLiteStore(path: AppPaths.databaseFile)
            self.monitor = TrafficMonitor(
                store: store, config: config, vultrAPIKey: vultrAPIKey
            )
        } catch {
            self.fatalError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    /// 把当前的呈现方式应用到 NSApplication。
    ///
    /// Info.plist 里的 LSUIElement 只决定启动时的初始状态，
    /// setActivationPolicy 可以在运行时切换，所以 Dock 图标能随开随关。
    func applyActivationPolicy() {
        NSApp.setActivationPolicy(displayMode.showsDockIcon ? .regular : .accessory)
    }

    /// 启动流程：先用本地数据把界面填满，再在后台发起真正的采集。
    /// 这样即使网络或 SSH 很慢，打开菜单也能立刻看到上次的数据。
    func start() async {
        guard let monitor else { return }
        statuses = await monitor.statuses()
        scheduleTimer()
        await refresh()
    }

    func refresh() async {
        guard let monitor, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        statuses = await monitor.refreshAll()
        lastRefreshAt = Date()
    }

    /// 重新按本地数据折算一遍。跨过账期重置日时需要它把界面切到新账期。
    func recomputeFromLocal() async {
        guard let monitor else { return }
        statuses = await monitor.statuses()
    }

    // MARK: - 配置

    func saveConfig() {
        do {
            try configStore.save(config)
            try KeychainStore.setVultrAPIKey(vultrAPIKey.isEmpty ? nil : vultrAPIKey)
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

    /// 用量比例最高的一台。
    var mostCritical: ServerStatus? {
        statuses
            .filter { $0.usedFraction != nil }
            .max { ($0.usedFraction ?? 0) < ($1.usedFraction ?? 0) }
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
