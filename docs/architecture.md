# 架构

这份文档讲的是**为什么这样拆**，而不是逐个文件的 API 说明 —— 后者读源码更快，
代码里的注释已经写清了每个决定的理由。

## 一句话概括

```
采集器（按服务商）  →  [按天的 rx/tx]
                            ↓
                 SQLite（覆盖式 upsert，跨采集累积）
                            ↓
        账期切分（resetDay）+ 口径折算（meterMode/unitBase）
                            ↓
                 用量 / 剩余 / 外推 / 是否会超额
```

关键在于**归一化发生得足够早**：不同服务商的差异在采集器这一层就被抹平，
往下的存储、账期、折算、UI 全都不知道数据来自哪家。

---

## 分层

### 1. 采集层 —— 唯一按服务商分叉的地方

`Collector` 协议（[`macos/Sources/VPSQuotaCore/Collectors/Collector.swift`](../macos/Sources/VPSQuotaCore/Collectors/Collector.swift)）
只有一个方法：

```swift
func fetch(server: ServerConfig, since: Date) async throws -> CollectResult
```

产出的 `CollectResult` 含三样东西：

| 字段 | 说明 |
|---|---|
| `days` | 按天的 rx/tx 字节数，UTC 日期 |
| `reportedQuotaGB` | 上游报告的月配额。只有 Vultr 有，SSH 恒为 `nil` |
| `warnings` | 采集成功但值得提醒的情况，例如服务器时区不是 UTC |

现有两个实现：

- **`VultrCollector`** —— 调两个官方端点：`GET /v2/instances` 拿 `allowed_bandwidth`，
  `GET /v2/instances/{id}/bandwidth` 拿每日 `incoming_bytes` / `outgoing_bytes`。
  日期键本身就是 UTC，不需要换算。
- **`SSHVnstatCollector`** —— 通过系统 `ssh` 执行 `vnstat --json d`。
  DMIT 没有公开 API，只能登服务器读网卡统计；这条路径适用于**任何能 SSH 的服务器**，
  不限于 DMIT。

**新增一家服务商，只需要多写一个 `Collector` 实现**，其余各层一行都不用改。
这是整个架构最重要的性质。

#### 一个容易忽略的细节：vnstat 的时区

vnstat 按**服务器本地时区**切分自然日，而本应用统一按 UTC 记账。
所以采集时会先执行 `date +%z` 拿到时区偏移，非 UTC 时挂一条 warning 提示用户 ——
这不是错误，但会让日切分有数小时偏差，用户需要知道。

#### 错误必须原样透出

`CollectError.commandFailed` 会把 SSH 的 stderr 原封不动带出来。
`Permission denied` / `Host key verification failed` / `command not found`
这三行几乎就是排查 SSH 问题的全部线索，吞掉它们等于让用户面对一个「连接失败」的黑盒。

### 2. 存储层 —— 为什么非要在本地留一份

Schema 是两端共用的唯一事实源：[`shared/schema.sql`](../shared/schema.sql)。

```sql
CREATE TABLE daily_usage (
    server_id TEXT, day TEXT,       -- day 是 UTC 的 YYYY-MM-DD
    rx_bytes INTEGER, tx_bytes INTEGER,
    PRIMARY KEY (server_id, day)
);
```

**主键是 `(server_id, day)`，写入是覆盖式 upsert 而不是忽略冲突** ——
当天的流量会持续增长，同一天必须能被反复改写。

之所以要本地留史，是因为上游窗口有限：

| 来源 | 窗口 |
|---|---|
| Vultr API | 约 30 天 |
| vnstat 日表 | 默认 62 天（`DayIsKept`） |

upsert 到本地之后历史可以无限累积。更实际的好处是**容错**：
某次采集失败，界面依然显示上次成功采集到的数据，而不是变成一片空白。

`fetch_log` 表记录每次采集的成败，用来在界面上显示「上次成功刷新时间」和失败原因。

### 3. 计算层 —— 纯函数，全部可单测

这一层没有任何 I/O，也不读墙上时钟（时间通过参数传入），所以能被完整覆盖。

**账期切分**（`BillingPeriod`）：左闭右开的 `[start, end)`。
账单日不一定是 1 号 —— DMIT 通常是开通日，Vultr 是账号计费日 —— 所以不能按自然月统计。
`resetDay` 会被钳制到 1–31，**当月天数不足时回退到月末**（例如 31 号遇上 2 月即为 2 月末）。

**口径折算**（`MeterMode` / `UnitBase`）：

- `meterMode` 决定怎么把 rx/tx 合成一个数：`outbound` / `inbound` / `sum` / `max`
- `unitBase` 决定 GB 的进制：`binary`（1024³）/ `decimal`（1000³）

这两个是**程序猜不出来的**，必须由用户对照服务商面板校准。
填错的代价：前者可能差一倍，后者差 7.4%。

**外推**（`ServerStatus.projectedGB`）：按已过天数的平均速度线性外推到账期末。
账期刚开始不足半天时返回 `nil` —— 样本太少，外推值会被瞬时波动放大到毫无参考价值。

**起始已用量补偿**（`UsageBaseline`）：中途接入时 vnstat 只有它开始记录之后的数据，
用户填一个当前已用量补上差额。**这个基准绑定当前账期，换账期自动失效** ——
否则它会在下个账期变成凭空多出来的流量。

`ServerStatus` 里所有派生值都基于同一个 `evaluatedAt`，而不是各自去读当前时间。
否则同一个状态对象里的几个数字会互相对不上，也没法写测试。

### 4. 调度层 —— 单台失败不能拖垮整个面板

`TrafficMonitor` 是一个 `actor`，UI 与 CLI 共用同一个入口。
刷新是并发的（`withTaskGroup`），而配置随时可能被设置界面改动，需要 actor 保护。

**失败隔离**是这层的核心约定：单台采集失败，错误记进 `fetch_log` 并挂在该台的
`lastError` 上，其余各台照常刷新，界面继续显示这台上次成功的数据。
一台机器 SSH 不通，不应该让整个面板变成空白。

---

## 两端对照

macOS 与 Windows 刻意保持**同名同职责**的目录结构，便于逐个文件对照：

| 职责 | macOS（Swift） | Windows（C#） |
|---|---|---|
| 采集抽象 | `Collectors/Collector.swift` | `Collectors/ICollector.cs` |
| Vultr 采集 | `Collectors/VultrCollector.swift` | `Collectors/VultrCollector.cs` |
| SSH 采集 | `Collectors/SSHVnstatCollector.swift` | `Collectors/SshVnstatCollector.cs` |
| 账期 | `Core/BillingPeriod.swift` | `Core/BillingPeriod.cs` |
| 折算 | `Core/QuotaCalculator.swift` | `Core/QuotaCalculator.cs` |
| 调度 | `Core/TrafficMonitor.swift` | `Scheduler/TrafficMonitor.cs` |
| 存储 | `Storage/SQLiteStore.swift` | `Storage/SqliteStore.cs` |
| 密钥 | `Storage/KeychainStore.swift`（钥匙串） | `Storage/SecretStore.cs`（DPAPI） |

改动一端的逻辑时，**对照着改另一端**。跨端一致性由两组测试兜底：

- `CrossPlatformConfigTests` —— 校验 `shared/config.example.json` 能被解析，字段名两端一致
- `SchemaConsistencyTests` —— 校验代码建出来的表结构与 `shared/schema.sql` 逐列一致

### macOS 端为什么拆两个 target

`VPSQuotaCore` 不引入任何 UI 框架，因此账期切分、口径折算、JSON 解析都能直接跑单测；
`VPSQuota`（菜单栏应用）和 `vpsquota-cli`（诊断工具）共用同一套刷新逻辑。

注意：`swift test` 只会编译 `VPSQuotaCore` 和测试 target，**UI 层的编译错误抓不到**，
所以 CI 里另有一步独立的 `swift build`。

### 密钥存储的两端差异

| | 机制 | 换机器后 |
|---|---|---|
| macOS | 系统钥匙串 | 可随钥匙串迁移 |
| Windows | DPAPI，`CurrentUser` 作用域 | **解不开**，当作「还没设置」处理，让用户重填 |

两端都**不把密钥写进 `config.json`**，所以配置文件可以放心备份、在两台机器间拷贝。

---

## 平台专属的取舍

**菜单栏图标可能消失。** 菜单栏拥挤时（尤其带刘海的机型）macOS 会静默丢弃放不下的状态项，
没有任何提示。所以应用不只依赖菜单栏，还提供 Dock 图标和 `open -a VPSQuota` 两条兜底入口。
「呈现方式」偏好存在 UserDefaults 而不是 `config.json` —— 它是 macOS 专属的界面设置，
不该混进两端共用、可互相拷贝的那份配置。

**.app 是手工组装的**（[`macos/scripts/build-app.sh`](../macos/scripts/build-app.sh)），
不用 Xcode 工程：SwiftPM 的包描述是纯文本、可 diff、可在命令行完整验证，
而菜单栏应用需要的只是一个正确的 bundle 结构和 `Info.plist`。
图标也用代码画（`scripts/make-icon.swift`），不往仓库里塞二进制资源。

签名是 ad-hoc（`codesign --sign -`），不需要开发者证书。代价是每次重新构建签名都会变，
macOS 会把它当成另一个应用，首次读取钥匙串时会重新弹授权框。
