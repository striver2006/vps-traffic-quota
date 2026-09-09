<div align="center">

# 📊 VPS 流量配额监控

---

### 流量配额监控 · VPS Traffic Quota Monitor

**跨平台（macOS / Windows）VPS 月度流量用量监控状态栏工具**

[![CI](https://github.com/striver2006/vps-traffic-quota/actions/workflows/ci.yml/badge.svg)](https://github.com/striver2006/vps-traffic-quota/actions/workflows/ci.yml) [![License](https://img.shields.io/badge/License-GPL--3.0-blue.svg)](LICENSE) ![Platform](https://img.shields.io/badge/Platform-macOS%2015%2B-000000?logo=apple&logoColor=white) ![Platform](https://img.shields.io/badge/Platform-Windows%2010%20%2F%2011-0078D6?logo=windows&logoColor=white) ![Swift](https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white) ![.NET](https://img.shields.io/badge/.NET-8.0-512BD4?logo=dotnet&logoColor=white) ![i18n](https://img.shields.io/badge/i18n-%E4%B8%AD%E6%96%87%20%7C%20English-success)

**简体中文** | [English](README.en.md)

</div>

---

监控 DMIT 与 Vultr 上多台 VPS 的月度流量用量，本地桌面常驻，定时自动采集。

- **macOS** —— 菜单栏常驻，图标旁直接显示指定那台的剩余流量（如 `1.94T` / `576G`，也可关掉只留图标）；
  鼠标移上去即浮出面板；另有主窗口作为兜底入口
- **Windows** —— 系统托盘常驻，图标颜色随用量变化；鼠标移上去即浮出面板

两端功能对等，共用同一份配置文件格式和本地数据库结构。

---

## 🎯 它解决什么问题 (The Problem)

DMIT 和 Vultr 的流量额度要分别登两个面板、逐台点开才能看到，
而超额的代价是限速或停机。这个工具把各家机器的用量集中到一处，
并按当前速度外推「这个月底会用到多少」，让你在撞上配额之前就知道。

## 🔌 数据从哪来 (Data Sources)

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

## 🚀 快速开始 (Quick Start)

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

装到应用目录：

```bash
cp -R build/VPSQuota.app /Applications/
```

首次启动后点菜单栏图标 → 设置，填入 API Key 和服务器。
要开机自启就在「设置 → 启动」里打开「登录时启动」，它会登记到
「系统设置 → 通用 → 登录项」，不必手工添加。

> 默认走 ad-hoc 签名，它不内嵌 designated requirement，macOS 只能按 cdhash 认应用；
> 而 cdhash 每次重编都变，钥匙串里那条「允许本应用访问」的授权随之失效 ——
> 于是每轮重编后首次读取 Vultr API Key 都会弹授权框，点「始终允许」即可。
>
> 嫌烦就换成固定证书签名：把证书指纹填进 `macos/scripts/signing-identity.local`
> （见同目录 `.example`），此后重编不再重复授权。任意代码签名证书都可以，
> 自签名的也行 —— 详见 [CONTRIBUTING.md](CONTRIBUTING.md#代码签名与公证)。

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

开机自启：在「设置 → 通用设置 → 启动」里勾选「开机时自动启动」。
它写的是当前用户的注册表启动项，不需要管理员权限，
随时可以在任务管理器的「启动应用」里禁用。

---

## ⚙️ 配置 (Configuration)

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

### 账期中途才开始监控？

vnstat 只统计它自己开始记录之后的流量，所以中途接入时本账期的数字会偏低。
在「设置 → 起始已用量」里填上服务商面板显示的当前已用量即可补齐，
该补偿值绑定当前账期，下个账期自动失效。

### 关于精度

工具读的是网卡实际收发的字节数（vnstat）或服务商 API 报告的值，
而计费用的是服务商交换机上的计数。两者通常接近但不会完全相等。

**这个工具的定位是提前预警，不是对账。** 逼近配额时以服务商面板为准。

---

## 📁 项目结构 (Project Layout)

```
├── shared/          两端共用的 schema 与配置模板
├── docs/            接入指南、配置参考、架构与需求
├── macos/           Swift Package
│   ├── Sources/VPSQuotaCore/    纯逻辑 + 采集 + 存储（可单测，无 UI 依赖）
│   ├── Sources/VPSQuota/        菜单栏应用
│   ├── Sources/vpsquota-cli/    诊断工具
│   └── Tests/                   单元测试（无 UI 依赖，可直接 swift test）
└── windows/         .NET 8 WPF 托盘应用
    └── VpsQuota/    目录结构与 macOS 端同名同职责，便于对照
```

macOS 端刻意把逻辑与 UI 拆成两个 target：`VPSQuotaCore` 不引入任何 UI 框架，
因此账期切分、口径折算、JSON 解析都能直接跑单测，
CLI 与图形界面也共用同一套刷新逻辑。

参与开发见 [CONTRIBUTING.md](CONTRIBUTING.md)，设计取舍见
[`docs/architecture.md`](docs/architecture.md)，
范围与非目标见 [`docs/requirements.md`](docs/requirements.md)。

---

## 📝 更新日志 (Changelog)

见 [CHANGELOG.md](CHANGELOG.md)。

## 📄 许可证 (License)

[GPL-3.0](LICENSE)
