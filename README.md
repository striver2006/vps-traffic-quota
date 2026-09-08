# VPS 流量配额监控

监控 DMIT 与 Vultr 上多台 VPS 的月度流量用量，本地桌面常驻，定时自动采集。

- **macOS** —— 菜单栏常驻，图标直接显示最紧张那台的用量百分比；另有主窗口作为兜底入口
- **Windows** —— 系统托盘常驻，图标颜色随用量变化

两端功能对等，共用同一份配置文件格式和本地数据库结构。

---

## 它解决什么问题

DMIT 和 Vultr 的流量额度要分别登两个面板、逐台点开才能看到，
而超额的代价是限速或停机。这个工具把四台机器的用量放在一个地方，
并按当前速度外推「这个月底会用到多少」，让你在撞上配额之前就知道。

## 数据从哪来

| 服务商 | 途径 | 说明 |
|---|---|---|
| **Vultr** | 官方 REST API | `GET /v2/instances` 取月配额，`GET /v2/instances/{id}/bandwidth` 取每日进出字节数 |
| **DMIT** | SSH + `vnstat` | DMIT 没有公开 API，只能登录服务器读网卡统计。这条路径适用于任何能 SSH 的服务器 |

两条路径产出的都是「按天的 rx/tx 序列」，之后走完全相同的计算逻辑 ——
按账单重置日切账期、按计费口径折算、存进本地 SQLite。
新增一家服务商只需要多写一个采集器。

```
采集器（按服务商）  →  [按天的 rx/tx]
                            ↓
                 SQLite（覆盖式 upsert，跨采集累积）
                            ↓
        账期切分（resetDay）+ 口径折算（meterMode/unitBase）
                            ↓
                 用量 / 剩余 / 外推 / 是否会超额
```

本地存一份历史很有必要：Vultr API 只给约 30 天窗口，vnstat 日表默认保留 62 天，
而 upsert 到本地之后历史可以无限累积，某次采集失败也不会让界面变空。

---

## 快速开始

### 1. 准备服务商侧

- Vultr → [`docs/setup-vultr.md`](docs/setup-vultr.md)（建 API Key，**注意 IP 白名单**）
- DMIT → [`docs/setup-dmit.md`](docs/setup-dmit.md)（装 vnstat，配免密 SSH）

### 2. macOS

需要 Xcode 命令行工具（Swift 6+，macOS 15+）。

```bash
cd macos
swift test                  # 跑单元测试
./scripts/build-app.sh      # 生成 build/VPSQuota.app
open build/VPSQuota.app
```

装到应用目录并开机自启：

```bash
cp -R build/VPSQuota.app /Applications/
# 系统设置 → 通用 → 登录项 → 添加 VPSQuota.app
```

首次启动后点菜单栏图标 → 设置，填入 API Key 和服务器。

#### 菜单栏图标看不到？

菜单栏拥挤时（**尤其是带刘海的机型**）macOS 会静默丢弃放不下的状态项，
图标就这么消失了，而且没有任何提示。所以应用不只依赖菜单栏，还有两条入口：

- **Dock 图标** —— 默认开启，点它就能打开主窗口
- **`open -a VPSQuota`** —— 终端里执行即可唤出主窗口，也方便绑到 Raycast / Alfred

在「设置 → 呈现方式」里可以切换「仅菜单栏 / 仅 Dock / 菜单栏 + Dock」，默认是后者。
这项偏好存在 UserDefaults 而不是 config.json —— 它是 macOS 专属的界面设置，
不该混进两端共用、可互相拷贝的那份配置。

#### 诊断工具

接真实凭据时，先用命令行工具逐项确认，比透过图形界面看报错快得多：

```bash
swift run vpsquota-cli set-key <VULTR_API_KEY>   # 写入钥匙串
swift run vpsquota-cli vultr-instances           # 列出实例与 allowed_bandwidth
swift run vpsquota-cli probe                     # 逐台测连通性
swift run vpsquota-cli refresh                   # 采集一次并打印用量
swift run vpsquota-cli status                    # 只读本地数据，不联网
```

### 3. Windows

需要 .NET 8 SDK，Windows 10 1803+（依赖系统自带的 OpenSSH 客户端）。

```powershell
cd windows
dotnet build VpsQuota.sln -c Release
.\VpsQuota\bin\Release\net8.0-windows\VpsQuota.exe
```

开机自启：把 `VpsQuota.exe` 的快捷方式放进
`shell:startup`（在运行框里输入即可打开该目录）。

---

## 配置

字段逐项说明见 [`docs/config-reference.md`](docs/config-reference.md)，
模板见 [`shared/config.example.json`](shared/config.example.json)。

| | 配置与数据位置 |
|---|---|
| macOS | `~/Library/Application Support/VPSTrafficQuota/` |
| Windows | `%APPDATA%\VPSTrafficQuota\` |

两端格式完全一致，`config.json` 可以直接拷贝。
API Key 不在其中（macOS 存钥匙串，Windows 用 DPAPI 加密），备份配置文件不会泄露凭据。

### ⚠️ 首次配置后务必校准

`meterMode`（单向/双向）和 `unitBase`（1024³/1000³）是仅有的两个
程序猜不出、填错会导致数字系统性偏差的字段 —— 前者可能差一倍，后者差 7.4%。
刷新一次后对照服务商面板的数字核对，方法见
[配置参考的「校准流程」](docs/config-reference.md#校准流程)。

### 关于精度

工具读的是网卡实际收发的字节数（vnstat）或服务商 API 报告的值，
而计费用的是服务商交换机上的计数。两者通常接近但不会完全相等。

**这个工具的定位是提前预警，不是对账。** 逼近配额时以服务商面板为准。

---

## 项目结构

```
├── shared/          两端共用的 schema 与配置模板
├── docs/            接入指南与配置参考
├── macos/           Swift Package
│   ├── Sources/VPSQuotaCore/    纯逻辑 + 采集 + 存储（可单测，无 UI 依赖）
│   ├── Sources/VPSQuota/        菜单栏应用
│   ├── Sources/vpsquota-cli/    诊断工具
│   └── Tests/                   38 项单元测试
└── windows/         .NET 8 WPF 托盘应用
    └── VpsQuota/    目录结构与 macOS 端同名同职责，便于对照
```

macOS 端刻意把逻辑与 UI 拆成两个 target：`VPSQuotaCore` 不引入任何 UI 框架，
因此账期切分、口径折算、JSON 解析都能直接跑单测，
CLI 与图形界面也共用同一套刷新逻辑。
