# DMIT（以及任何无 API 的服务商）接入指南

DMIT 没有公开的 API，面板数据也没有可供程序读取的接口。因此本工具改为
**SSH 登录到服务器上执行 `vnstat`**，读取网卡自身的流量统计。

这条路径同样适用于任何能 SSH 登录的服务器，不限于 DMIT。

> **一个必须先说清楚的前提**：vnstat 统计的是**网卡实际收发的字节数**，
> 而服务商计费用的是**它们自己交换机上的计数**。两者通常很接近但不会完全相等
> （封装开销、计费起止时刻、是否计入内网流量等都会造成差异）。
> 本工具的定位是「提前预警」，不是「对账」。请把它当作趋势参考，
> 在逼近配额时以服务商面板的数字为准。

---

## 一、在 VPS 上安装 vnstat

SSH 登录到服务器后执行（Debian / Ubuntu）：

```bash
apt update && apt install -y vnstat
systemctl enable --now vnstat
```

CentOS / Rocky / AlmaLinux：

```bash
dnf install -y epel-release && dnf install -y vnstat
systemctl enable --now vnstat
```

Alpine：

```bash
apk add vnstat && rc-update add vnstatd && rc-service vnstatd start
```

### 确认它在工作

```bash
vnstat --json d 3
```

应该输出一段 JSON。**刚装好时日流量记录可能是空的**，vnstat 需要运行几分钟
才会写入第一条记录；如果输出里 `"day": []`，等一会儿再试。

### 确认网卡名

```bash
ip -o link | awk -F': ' '{print $2}'
```

常见是 `eth0`、`ens3`、`venet0`。把公网网卡的名字填进本工具的「网卡」一栏。
留空的话工具会用 vnstat 返回的第一块网卡，多网卡机器上未必是你想要的那块。

如果 vnstat 没有在统计你要的网卡，加进去：

```bash
vnstat --add -i eth0
systemctl restart vnstat
```

---

## 二、配置免密 SSH 登录

本工具**只支持密钥认证**，不支持密码 —— 后台采集不能停下来等人输密码。

在你的 **Mac / Windows 本机**上（不是 VPS 上）执行：

```bash
# 若还没有密钥就先生成一把
ssh-keygen -t ed25519 -C "vps-traffic-quota"

# 把公钥装到服务器（把 root@1.2.3.4 和端口换成实际值）
ssh-copy-id -p 22 root@1.2.3.4
```

Windows 上如果没有 `ssh-copy-id`，手动追加：

```powershell
type $env:USERPROFILE\.ssh\id_ed25519.pub | ssh -p 22 root@1.2.3.4 "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
```

### 验证（这一步必须通过，否则工具一定采集不到数据）

```bash
ssh -o BatchMode=yes -p 22 root@1.2.3.4 "vnstat --json d 2"
```

`BatchMode=yes` 会禁止一切交互提问，工具内部用的正是这个参数。
如果这条命令能直接输出 JSON，工具就一定能采到数据；如果它卡住或报错，
先把它修好再回到工具里。

常见错误：

| 报错 | 原因与处理 |
|---|---|
| `Permission denied (publickey)` | 公钥没装好，或服务器 `~/.ssh/authorized_keys` 权限不对（应为 600） |
| `Host key verification failed` | 首次连接未确认，或服务器重装过。先手动 `ssh root@1.2.3.4` 确认一次指纹 |
| `bash: vnstat: command not found` | 第一步没做，或 vnstat 装在了非登录 shell 的 PATH 之外 |
| 卡住不动 | 服务器在等密码。说明密钥认证没生效，回到上一步 |

---

## 三、（推荐）把服务器时区设成 UTC

vnstat 按**服务器本地时区**切分自然日，而本工具统一按 **UTC** 记账。
时区不一致时，账期首尾两天会有几小时的流量归属偏差 —— 量不大，但账期临界时会让人困惑。

```bash
timedatectl set-timezone UTC
```

工具会自动检测这一点：服务器时区不是 UTC 时，界面上会显示一条提醒，但不影响使用。

---

## 四、在工具里填写

| 字段 | 填什么 |
|---|---|
| 名称 | 随便起，只用于显示 |
| 主机 / 端口 / 用户名 | 与你 `ssh` 命令里用的完全一致 |
| 私钥路径 | 例如 `~/.ssh/id_ed25519`。留空则交给 ssh 按自身配置决定 |
| 网卡 | 上面查到的公网网卡名 |
| 月配额 | **从你的订单或工单确认**，程序无法探测 |
| 计费口径 | DMIT 分单向（仅出站）和双向套餐，**看你买的是哪种** |
| GB 进制 | 先用默认的 1024³，然后按下面的方法校准 |
| 每月重置日 | 通常是你的开通日 / 续费日 |

填完点「测试连接」，成功后会立刻采集一次。

---

## 五、如果是账期中途才装的 vnstat

`vnstat --json d` 只会返回它自己记录过的日子。**在账期中途才装上 vnstat 的话，
之前那段的流量本地是没有的**，面板会显示得远低于真实值。

去 DMIT 面板抄一下当前账期的已用量，填进工具的
「起始已用量 → 开始监控前已用（GB）」。这个补偿值只对当前账期有效，
下个账期开始后自动清零，不需要你回来手动删。

怎么确认 vnstat 是从哪天开始记的：

```bash
vnstat --json d 62 | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["interfaces"][0]["traffic"]["day"][0]["date"])'
```

---

## 六、校准（重要，别跳过）

**计费口径**和**GB 进制**填错，会让数字系统性地偏离服务商面板 ——
双向 vs 单向可能差一倍，进制差 7.4%。这两项程序猜不出来，必须对照校准一次：

1. 在工具里刷新一次，记下「已用」的数字
2. 打开 DMIT 面板，看它显示的本月已用流量
3. 两者比较：
   - **差了大约一倍** → 计费口径填反了（把「进出双向相加」换成「仅出站」，或反过来）
   - **差 7% 左右** → GB 进制填反了（在 1024³ 和 1000³ 之间切换）
   - **差几个百分点** → 正常，是统计口径的固有差异，不用管

校准一次即可，之后不用再动。
