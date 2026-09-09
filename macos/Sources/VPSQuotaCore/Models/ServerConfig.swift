import Foundation

/// 服务器的数据来源类型。
public enum ProviderKind: String, Codable, CaseIterable, Sendable {
    /// 通过 Vultr 官方 REST API 采集
    case vultr
    /// 通过 SSH 执行 vnstat 采集（DMIT 及任何没有 API 的服务商都走这条）
    case ssh

    public var displayName: String {
        switch self {
        case .vultr: return "Vultr API"
        case .ssh: return "SSH + vnstat"
        }
    }
}

/// 一台被监控的服务器。
///
/// 两端（macOS / Windows）共用同一份 JSON schema，字段名不可随意改动。
public struct ServerConfig: Codable, Identifiable, Hashable, Sendable {
    /// 本地唯一标识，同时作为 SQLite 中 daily_usage.server_id 的取值。改动它会丢失历史数据。
    public var id: String
    /// 显示名称
    public var name: String
    public var provider: ProviderKind

    /// 月配额（GB）。Vultr 服务器填 0 表示自动采用 API 返回的 allowed_bandwidth。
    public var quotaGB: Double
    public var meterMode: MeterMode
    /// 每月账单重置日（1–31）。当月没有该日时按当月最后一天处理。
    public var resetDay: Int
    /// 该服务商的 GB 进制。默认 binary（1024³），首次接入时对照面板校准。
    public var unitBase: UnitBase
    /// 本账期的「起始已用量」基准，用于补上开始采集之前就已消耗的流量。
    /// 只对它记录的那个账期生效，换账期后自动失效。
    public var usageBaseline: UsageBaseline?

    // MARK: Vultr 专用
    public var vultrInstanceId: String?

    // MARK: SSH 专用
    public var sshHost: String?
    public var sshPort: Int?
    public var sshUser: String?
    /// 私钥路径，支持 ~ 开头。为空则交给 ssh 按 ~/.ssh/config 自行决定。
    public var sshKeyPath: String?
    /// vnstat 要统计的网卡名。为空则让 vnstat 用默认网卡。
    public var interface: String?

    /// 逐字段兜底解码：`unitBase` 等后加字段在旧配置文件中不存在，
    /// 不能因为缺一个键就让整份配置读不出来。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.provider = try c.decode(ProviderKind.self, forKey: .provider)
        self.quotaGB = try c.decodeIfPresent(Double.self, forKey: .quotaGB) ?? 0
        self.meterMode = try c.decodeIfPresent(MeterMode.self, forKey: .meterMode) ?? .outbound
        self.resetDay = try c.decodeIfPresent(Int.self, forKey: .resetDay) ?? 1
        self.unitBase = try c.decodeIfPresent(UnitBase.self, forKey: .unitBase) ?? .binary
        self.usageBaseline = try c.decodeIfPresent(UsageBaseline.self, forKey: .usageBaseline)
        self.vultrInstanceId = try c.decodeIfPresent(String.self, forKey: .vultrInstanceId)
        self.sshHost = try c.decodeIfPresent(String.self, forKey: .sshHost)
        self.sshPort = try c.decodeIfPresent(Int.self, forKey: .sshPort)
        self.sshUser = try c.decodeIfPresent(String.self, forKey: .sshUser)
        self.sshKeyPath = try c.decodeIfPresent(String.self, forKey: .sshKeyPath)
        self.interface = try c.decodeIfPresent(String.self, forKey: .interface)
    }

    public init(
        id: String,
        name: String,
        provider: ProviderKind,
        quotaGB: Double = 0,
        meterMode: MeterMode = .outbound,
        resetDay: Int = 1,
        unitBase: UnitBase = .binary,
        usageBaseline: UsageBaseline? = nil,
        vultrInstanceId: String? = nil,
        sshHost: String? = nil,
        sshPort: Int? = nil,
        sshUser: String? = nil,
        sshKeyPath: String? = nil,
        interface: String? = nil
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.quotaGB = quotaGB
        self.meterMode = meterMode
        self.resetDay = resetDay
        self.unitBase = unitBase
        self.usageBaseline = usageBaseline
        self.vultrInstanceId = vultrInstanceId
        self.sshHost = sshHost
        self.sshPort = sshPort
        self.sshUser = sshUser
        self.sshKeyPath = sshKeyPath
        self.interface = interface
    }
}

/// 应用整体配置，对应 config.json 的顶层结构。
public struct AppConfig: Codable, Sendable {
    /// 自动刷新周期（分钟）。UI 提供 15 / 60 / 360 / 1440 四档。
    public var refreshIntervalMinutes: Int
    public var servers: [ServerConfig]

    /// 常驻区（macOS 菜单栏 / Windows 托盘）要显示剩余流量的那台服务器。
    ///
    /// 放进共享配置而不是各端的本地偏好：两端的常驻区都只有一个位置，
    /// 该显示哪台是同一个决策，配置文件互拷时理应一起带过去。
    /// 为 nil、或指向一台已被删除的服务器时，回退到用量比例最高的那台。
    public var menuBarServerId: String?

    public init(
        refreshIntervalMinutes: Int = 60,
        servers: [ServerConfig] = [],
        menuBarServerId: String? = nil
    ) {
        self.refreshIntervalMinutes = refreshIntervalMinutes
        self.servers = servers
        self.menuBarServerId = menuBarServerId
    }

    /// 旧配置文件缺字段时的兜底，避免一次手改 JSON 就整个读不出来。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.refreshIntervalMinutes =
            try c.decodeIfPresent(Int.self, forKey: .refreshIntervalMinutes) ?? 60
        self.servers = try c.decodeIfPresent([ServerConfig].self, forKey: .servers) ?? []
        self.menuBarServerId = try c.decodeIfPresent(String.self, forKey: .menuBarServerId)
    }
}
