# 菜单栏图标不显示：排查与解决

> 症状：应用在运行、进程健康、流量刷新正常，但菜单栏上**看不到图标**。
> 一句话结论：macOS 26 的 ControlCenter 把 `io.vpsquota.VPSTrafficQuota` 的菜单栏项
> 拉黑了（日志特征 `Moving host to blocked list`）。拉黑不是按"这个应用自己的开关"
> 判的，而是按**负责进程**归属 —— 只要本 bundle id 出现在任意一条 `isAllowed=false`
> 记录的 `menuItemLocations` 里就被隐藏。
>
> **解除办法：到「系统设置 › 控制中心 › 菜单栏 › 应用程序」把那一行开关打开。**
> 秒生效，正在跑的进程不用重启。

## 一、症状与快速定性

| 观察 | 表现 |
| :--- | :--- |
| 应用侧日志 | `状态项[…] verdict=detached(notMirrored) … mirror=false`（error 级），重建后依旧 |
| ControlCenter 日志 | 运行中被拉黑：`Moving host to blocked list` → `Stopping tracking for host` → `Starting to track blocked host` 三连；启动时就已被拉黑：只有最后一条 |
| 重启应用 / 重建状态项 | 无效 —— 每个新 PID 照样秒拒 |
| 应用界面 | 主窗口与设置界面顶部出现「菜单栏图标被系统隐藏」横幅 |

**状态项窗口的 frame 有两种形态，判定必须同时认得**（2026-09-14 真机实测）：

| 场景 | frame | 说明 |
| :--- | :--- | :--- |
| 运行中被拉黑 | `2651,1418 79x22` | 保留着之前拿到的位置，`maxY` 仍贴齐屏幕顶边 —— **纯几何判定会判它 healthy**，只能靠镜像信号识别 |
| 启动 / 重建时已被拉黑 | `0,-22 79x22` | 从未被布局。ControlCenter 不给槽位，AppKit 就永远不会布局它，**且不会自己恢复** |

第二种形态是个陷阱：它落在所有屏幕之外，看起来像"几何跑飞"，但判成 `offMenuBar`
就会去走结构性重建梯（重建对拉黑无效），永远到不了 `blockedBySystem`，横幅也就永远不出现。
`StatusItemHealth.evaluate` 里"窗口不与任何屏幕相交 → `notMirrored`"这条判定专治此症，
有回归测试锁着，别去动它的顺序。

**最可靠的健康信号是"控制中心有没有为它渲染镜像"**（layer-25、onscreen、同 x 同宽的
ControlCenter 窗口），应用内已实现（`MenuBarMirror.isMirrored`）；`mirror=false` 基本
等价于被拉黑。

快速定性两条命令：

```bash
# ControlCenter 是否正在拉黑我们（Default 级，可回溯）
command log show --last 30m --predicate 'process == "ControlCenter"' --info --debug \
  | grep -E "Moving host to blocked" | grep -i vpsquota | tail -5

# 应用侧健康判定（.info 级不落盘，必须现场盯）
command log stream --predicate 'subsystem == "io.vpsquota.VPSTrafficQuota"' --level debug --style compact
```

> 注意两处 macOS/zsh 坑：调系统日志必须写 `command log`（zsh 的 `log` 是内建命令，
> 直接写会报 `too many arguments`）；健康判定日志是 `.info` 级，事后 `log show` 查不到。
> 解除瞬间的 `Unblocking host` 同样只在 stream 里看得到。

## 二、真因：ControlCenter 的 trackedApplications 表

落盘位置（2026-09-14 sudo 拷出解码确认）：

```
~/Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter.plist
```

该目录受 TCC 保护，普通 shell 连 `ls` 都是 `Operation not permitted`，要 `sudo cp` 出来再解。
（同目录的 `group.com.apple.secure-control-center-preferences/…av.plist` 是音视频权限的，不相干。）

顶层键 `showSpotlight` / `showWeather` / `trackedApplications`，最后一个是一段嵌套 bplist，
内容是 `[TrackedApplicationLocation: TrackedApplication]` 字典（数组形式 key、value 交替），
本机共 64 条。每条：

```
TrackedApplication { location, menuItemLocations: [Location], isAllowed }
Location = bundle(<bundle id>) | adhocBinary(<file URL>)
```

实测样本（与本项目相关的几条）：

| 记录（location） | isAllowed | menuItemLocations |
| :--- | :--- | :--- |
| `bundle:com.microsoft.VSCode` | **false** | com.unidrop.client, com.tokenbar.mac, **io.vpsquota.VPSTrafficQuota**, com.unidrop.traytest |
| `bundle:dev.zcode.app` | false | com.tokenbar.mac |
| `bundle:com.tokenbar.mac` | true | com.tokenbar.mac（自己那条是放行的，照样被拉黑） |
| `adhoc:…/.build/…/debug/TokenBar` | true | 自身（裸可执行文件独立成记录，所以能上屏） |

**判定规则**（与 ControlCenter 反汇编里"遍历集合 → 比较 → 命中即处理"的循环吻合）：

> 新 host 的 bundle id 只要出现在**任意一条** `isAllowed=false` 记录的 `menuItemLocations`
> 里，就被拉黑，**与它自己那条记录的开关无关**。

「系统设置 › 菜单栏 › 应用程序」列表里每一行就是一条记录。

## 三、怎么挂到 IDE 名下的

从 IDE 的集成终端直接执行可执行文件时（`swift run`、`./.build/debug/VPSQuota`、
`build/VPSQuota.app/Contents/MacOS/VPSQuota`），进程的**负责进程（responsible process）**
是 IDE，ControlCenter 按负责进程归属菜单项 —— 于是本应用的菜单栏项被记进了 IDE 那条记录的
`menuItemLocations`，IDE 那行开关一关，本应用跟着遭殃。

用 `open` 启动的 .app 由 launchd 负责，不会被归到 IDE 下。

**已经挂错的归属不会自动清理。**

## 四、解除与预防

### 4.1 解除（实测有效）

系统设置 › 控制中心 › 菜单栏 › 应用程序，把**负责它的那一行**开关打开：

- 开发场景：打开 Visual Studio Code / ZCode 等 IDE 那一行；
- 用户场景：打开「VPS 流量」自己那一行。

2026-09-14 17:4x 实测：开关打开的瞬间 ControlCenter 日志出现
`Unblocking host; (bid:…)`，**正在运行的进程无需重启即恢复**；之后新启动的进程只出现
`Starting to track host`，layer-25 上出现状态项镜像，图标回来。
副作用只是允许这些 IDE "名下"的菜单项显示，IDE 自身并没有状态项。

> 只想让本应用那行开关起作用而不动 IDE 的开关：`sudo` 拷出上述 plist，用 plistlib 从
> VS Code / ZCode 记录的 `menuItemLocations` 里删掉 `io.vpsquota.VPSTrafficQuota`，
> 写回原路径（保持 600 权限）后 `killall ControlCenter`。属于改系统偏好文件，优先走上一步。

### 4.2 已实测无效的手段

| 手段 | 结果 |
| :--- | :--- |
| 清 LaunchServices 死记录（`lsregister -u` / stub 注销法 / `-gc`） | ❌ 无效 —— 与拉黑无因果关系 |
| `killall ControlCenter`（自动重生） | ❌ 无效 |
| `tccutil reset All io.vpsquota.VPSTrafficQuota` | ❌ 无效 |
| 整机重启 / 注销重登 | ❌ 无效 |
| 把应用自己那行开关关掉再打开 | ❌ 无效（只写 `Preferences: changed`，不改 IDE 记录） |
| **打开负责它那一行的开关** | ✅ 秒生效，进程无需重启 |

> 历史留档：本文 2026-09-14 早先的版本把根因写成"LaunchServices 死记录触发 + 会话态粘性"，
> 当天晚些时候的受控实验（解码 `trackedApplications`）证伪了这两条。相关的应用内清理代码
> （`LaunchServicesJanitor`）已删除。

### 4.3 预防

**开发时不要在 IDE 集成终端里直接执行可执行文件**，构建后一律：

```bash
./scripts/build-app.sh && open build/VPSQuota.app
# 或
open -a VPSQuota
```

`build-app.sh` 保留的 `lsregister -u`（`--clean` / `--install` 前先注销）与 `ditto` 装包
属于**常规卫生**（避免 `open -a` 解析到已删路径、避免 `cp -R` 嵌套成
`VPSQuota.app/VPSQuota.app`），**与拉黑无关**，别再把它当防线。

## 五、分场景处置

应用无法可靠区分自己属于哪种场景，所以横幅文案把两条都写了。

**开发者场景**：负责进程 = IDE。表现是"我什么都没改，图标就没了"。
处置：打开 IDE 那一行；预防：见 4.3。

**用户场景**：终端用户走 `open` / launchd / 登录项，**不会**被归到 IDE 下，不会撞上这条。
但同样会落到 `blockedBySystem` —— 他自己在「系统设置 › 控制中心 › 菜单栏 › 应用程序」里
把「VPS 流量」那一行关掉了（或误关）。处置：打开自己那一行。

2026-09-14 实测确认：在系统设置里关掉自己那一行走的是 **`notMirrored`**，
判定日志里 `visible=true` —— 那个开关**不会**改 `NSStatusItem.isVisible`，
所以不会撞上 `userHidden` 分支（那条是用户 Cmd 拖走图标才会走的）。
两种场景的表现完全一致：14 秒判定、只重建 1 次、frame 同样变成 `0,-22`。

## 六、应用内状态项管理设计

为避免轮询采样带来性能损耗以及外接屏切换/休眠唤醒时的假阳性误判重建（导致图标闪烁跳动），应用已移除自动检测看门狗与 UI 警告横幅，全面回归标准 AppKit 生命周期管理：

- **生命周期**：由 `StatusItemController` 常驻持有 `NSStatusItem` 引用。除非用户在「呈现方式」设置中关闭菜单栏项，否则状态项保持常驻。
- **纯净界面**：不再常驻扫描窗口镜像，不再弹出「菜单栏图标被系统隐藏」横幅或强制弹窗，保持界面安静纯粹。
- **系统放行**：如遇 macOS 控制中心按进程拉黑，请按上方第二节步骤在系统设置中直接放行即可。

## 七、手动排查手册

### 7.1 解码 trackedApplications，确认是谁把我们拉黑了

```bash
CC="$HOME/Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter.plist"
sudo cp "$CC" /tmp/cc.plist && sudo chown "$(id -un)" /tmp/cc.plist

python3 - <<'PY'
import plistlib
d = plistlib.load(open('/tmp/cc.plist','rb'))
inner = plistlib.loads(d['trackedApplications'])   # 内层还是 bplist
print(inner)   # [location, app, location, app, …] 交替；找 isAllowed=False 且
               # menuItemLocations 里含 io.vpsquota.VPSTrafficQuota 的那条
PY
```

### 7.2 验证流程（装包后必做）

```bash
# 1. 先起日志流（.info 级不落盘，必须现场盯）
command log stream --predicate 'subsystem == "io.vpsquota.VPSTrafficQuota"' --level debug --style compact

# 2. 另开终端：构建 + 安装 + 启动
./scripts/build-app.sh --install
```

预期（健康）：`状态项[launch+2s] verdict=healthy … mirror=true frameOK=true state=healthy`。

被拉黑时的完整序列（2026-09-14 真机实测，从启动到判定 14 秒）：

```
launch+2s    verdict=detached(notMirrored) win=0,-22  state=unknown
launch+5s    verdict=detached(notMirrored)            → 状态项重建：结构性=0次 镜像=1次
post-rebuild verdict=detached(notMirrored) win=0,-22  （重建也拿不到槽位）
launch+15s   状态项被 ControlCenter 拉黑隐藏：重建无效，已停止重建
launch+60s   state=blockedBySystem                    （只 probe，零重建）
```

放行后（实测 0.85 秒）：

```
ControlCenter  Unblocking host; (bid:io.vpsquota.VPSTrafficQuota-VPSQuota-<pid>)
应用           verdict=healthy mirror=true → 菜单栏拉黑已解除，状态项恢复渲染
               state=healthy mirrorRebuilds=0（重建预算已归还）
```

**不需要重启应用，更不需要重启系统。**

---
*2026-09-14 修订：根因由受控实验（解码 `trackedApplications`）确定，
推翻了同日早先"LaunchServices 死记录 + 会话态粘性"的结论。
如结论再被后续验证修正，先更新本文与 `docs/architecture.md` 对应段落。*
