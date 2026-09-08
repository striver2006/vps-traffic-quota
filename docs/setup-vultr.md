# Vultr 接入指南

Vultr 提供官方 REST API，本工具直接调用，无需登录服务器，也不用装任何东西。

用到两个端点：

| 端点 | 取什么 |
|---|---|
| `GET /v2/instances` | 实例列表，以及每台的 `allowed_bandwidth`（月配额，GB） |
| `GET /v2/instances/{id}/bandwidth` | 按天的 `incoming_bytes` / `outgoing_bytes`，UTC 日期 |

> **注意**：Vultr 官方明确说明带宽数据是**周期性刷新**的，不是实时值。
> 把刷新周期设成 15 分钟并不会让数据更新，反而只是白白多打 API。
> 推荐每小时或每 6 小时。

---

## 一、创建 API Key

1. 登录 Vultr 后台 → 右上角头像 → **Account** → **API**
2. 在 **Personal Access Token** 处点 **Enable API**，复制生成的 Key

### ⚠️ 必须同时处理 IP 白名单

同一个页面下方有 **Access Control**，Vultr **默认只允许特定 IP 调用 API**。
如果不把你的出口 IP 加进去，所有请求都会返回 **403**。

查你当前的出口 IP：

```bash
curl -s https://api.ipify.org
```

把它填进 Access Control 的允许列表（IPv4 和 IPv6 都要，如果你有 IPv6）。

> 家用宽带的 IP 通常会变。如果工具某天突然全部报 403，
> 第一件事就是回来看这里的 IP 是不是过期了。

---

## 二、填入工具

在设置界面的「Vultr API Key」处粘贴。密钥的存放位置：

- **macOS**：系统钥匙串
- **Windows**：用 DPAPI 以当前用户身份加密，存在 `%APPDATA%\VPSTrafficQuota\secrets.bin`

两者都**不写入 config.json**，所以配置文件可以放心备份或在两台机器间拷贝。

---

## 三、拿到实例 ID

最省事的办法是用附带的诊断工具（macOS）：

```bash
cd macos
swift run vpsquota-cli set-key <你的_API_KEY>
swift run vpsquota-cli vultr-instances
```

它会列出账号下所有实例的 ID、IP、区域和月配额。

也可以从后台拿：打开某台实例的详情页，浏览器地址栏里
`https://my.vultr.com/subs/?SUBID=...` 之后的那串 UUID 就是。

---

## 四、配额与计费口径

- **月配额**填 `0`，工具会自动采用 API 返回的 `allowed_bandwidth`，不用手填也不会填错。
  只有当你和 Vultr 单独谈过额度、API 报告的值不准时才需要手填。
- **计费口径**默认「仅出站（单向）」—— Vultr 通常按出站计费。
- **每月重置日**是你的账号计费日，不一定是 1 号，在后台 Billing 页面能看到。

配好之后按 `docs/setup-dmit.md` 里「校准」那一节的方法，
用 Vultr 面板的 **Billing → Bandwidth** 页面核对一次数字。
