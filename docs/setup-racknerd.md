# RackNerd 接入指南

RackNerd 的 VPS 多通过 SolusVM（NerdVM 控制面板，默认 `https://nerdvm.racknerd.com`）管理，提供标准的 Client API，本工具直接调用获取带宽信息，无需登录服务器，也无需安装任何客户端。

---

## 一、获取 API Key 与 API Hash

1. 登录你的 RackNerd VPS 控制面板（通常地址为 `https://nerdvm.racknerd.com/`，以开通邮件提供的控制面板地址为准）。
2. 在虚拟服务器列表中进入你要监控的那台 VPS。
3. 点击 **API** 选项卡。
4. 如果尚未生成密钥，点击 **Generate** 按钮；系统将生成该实例专用的 **API Key** 与 **API Hash**。

> ⚠️ RackNerd 的 API Key 与 Hash 是**按每台 VPS 独立生成的**。密钥拥有控制该 VPS 的权限，请妥善保管，不要写入明文配置文件或分享给他人。

---

## 二、填入配置界面

在应用设置中：**设置 → 服务器配置 → 添加 → RackNerd**：

| 字段 | 说明与填写建议 |
|---|---|
| **API Key** | NerdVM 面板 API 选项卡生成的 API Key（存储在系统安全钥匙串 / Windows DPAPI，**不写进 config.json**） |
| **API Hash** | NerdVM 面板 API 选项卡生成的 API Hash（存储在系统安全钥匙串 / Windows DPAPI，**不写进 config.json**） |
| **端点 URL（可选）** | 若你的控制面板在其他主控地址，可填写自定义端点（如 `https://nerdvm.racknerd.com/api/client/command.php`）；留空默认使用官方 nerdvm 端点 |
| **月配额** | 填 `0`：自动采用 API 报告的总带宽（与面板一致） |
| **每月重置日** | 根据账单周期填写（通常为每个月的 1 号或开通日） |
| **计费口径** | 推荐「仅出站」或「进出双向相加」 |
| **GB 进制** | 默认 binary（1024³） |

填完后点击「测试连接并采集」，即可验证连通性并拉取当前用量与配额。

### 命令行诊断（macOS）

在未保存配置前，也可以直接通过命令行测试 API：

```bash
cd macos
swift run vpsquota-cli racknerd-probe <API_KEY> <API_HASH>
```

---

## 三、工作原理

RackNerd Client API（`action=info&bw=true`）返回的是当前计费周期内的累计带宽统计（`total,used,free,percent` 字节数）。

本工具在本地记录每日状态快照（`racknerd-state/<serverId>.json`），以差值方式还原每日用量：
- **当天用量** = 当前累计计数器 − 当日基线，幂等重算；
- **换账期**：当计数器回落时，基线自动归零；
- **跨天**：以昨日最终观测值作为今日新基线；
- **首次接入**：将已有累计用量计入接入当天。
