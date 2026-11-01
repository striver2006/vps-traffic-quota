# Hetzner Cloud 接入指南

Hetzner Cloud 提供官方 REST API，本工具直接调用 `GET /v1/servers/{id}` 获取当月流量用量与配额，无需登录服务器，也无需安装任何客户端。

---

## 一、获取 API Token 与 Server ID

### 1. 创建 API Token
1. 登录 [Hetzner Cloud Console](https://console.hetzner.cloud/)。
2. 选择你要监控的服务器所在的项目（Project）。
3. 左侧导航进入 **Security** → **API Tokens**。
4. 点击 **Generate API Token**，名称自定，权限选择 **Read**（只需读取权限，无需 Write）。
5. 复制生成的 API Token。

### 2. 获取 Server ID
1. 在项目中的 **Servers** 列表，点击目标服务器进入详情页。
2. 浏览器地址栏中的 URL 格式形如：
   `https://console.hetzner.cloud/projects/<project_id>/servers/<server_id>/overview`
   其中的 `<server_id>`（纯数字，例如 `421093`）即为 Server ID。也可以在服务器概览页面的详细信息中找到。

---

## 二、填入配置界面

### 1. 通用设置（推荐）
在设置界面中：**设置 → 通用设置 → Hetzner API**：
- 填入你的 **Hetzner API Token**。
- 该 Token 将作为默认凭据供该项目下所有 Hetzner 云服务器共享使用，保存在系统钥匙串 / Windows DPAPI，**不写入 config.json**。

### 2. 服务器配置
在设置界面中：**设置 → 服务器配置 → 添加 → Hetzner**：

| 字段 | 说明与填写建议 |
|---|---|
| **Server ID** | 填入上述纯数字实例 ID（随配置文件保存） |
| **API Token（可选覆盖）** | 若该服务器属于其他项目或需要单独的 Token，可在此填写；留空则自动使用通用设置中的全局 Token |
| **月配额** | 填 `0`：自动采用 API 报告的 `included_traffic`（如 20 TB） |
| **每月重置日** | 填 `1`（Hetzner Cloud 账单和包含流量均按日历月 1 号重置） |
| **计费口径** | 保持「仅出站」（Hetzner 官方主要针对出站流量计费，入站通常免费） |
| **GB 进制** | 默认 binary（1024³） |

填完后点击「测试连接并采集」，即可验证连通性并拉取当前用量与配额。

### 命令行诊断（macOS）

在未保存配置前，可以通过命令行诊断工具直接测试：

```bash
cd macos
# 列出项目下所有云主机及流量
swift run vpsquota-cli hetzner-instances <API_TOKEN>

# 查单台主机的用量与配额
swift run vpsquota-cli hetzner-probe <SERVER_ID> <API_TOKEN>
```

---

## 三、工作原理

Hetzner Cloud API 会在服务器信息中直接返回本月累计的出站流量（`outgoing_traffic`）、入站流量（`ingoing_traffic`）和包含流量（`included_traffic`）。

本工具在本地记录快照（`hetzner-state/<serverId>.json`），以差值方式还原每日 rx 与 tx：
- **当天用量** = 当前累计计数器 − 当日基线，幂等重算；
- **换账期**：自然月翻页（每月 1 日）或计数器回落时基线归零；
- **跨天**：以昨日最终值作为今日基线；
- **配额**：自动将 `included_traffic` 转换为 GB 供配额监控。
