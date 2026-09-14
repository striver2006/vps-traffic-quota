# 菜单栏图标不显示：排查与解决

> 症状：应用在运行、进程健康、流量刷新正常，但菜单栏上**看不到图标**。
> 一句话结论：macOS 26 的 ControlCenter 把 `io.vpsquota.VPSTrafficQuota` 这个
> bundle id 的状态项拉黑了（日志特征 `Moving host to blocked list`）；触发器是
> LaunchServices 死记录，而拉黑本身是**按 bundle id 的粘性会话态**——清掉死记录
> 只是必要卫生，不足以解除已经存在的拉黑。
>
> 机制结论与受控实验来自 TokenBar 项目（2026-09-13/14，同机验证），
> 详见其 `doc/TROUBLESHOOTING_菜单栏图标不显示.md`；本文是本项目的操作手册。
> 本项目于 2026-09-14 中招（14:49 起被拉黑），并移植了其全套自愈机制。

## 一、症状与快速定性

| 观察 | 表现 |
| :--- | :--- |
| 应用侧日志 | `状态项[launch+2s] verdict=detached(notMirrored) … mirror=false`（error 级，重建后依旧） |
| 几何 | frame 可以完全正常，**纯几何判定会误判健康** |
| ControlCenter 日志 | `Moving host to blocked list; (bid:io.vpsquota.VPSTrafficQuota-VPSQuota-<pid>)`，出现在 host 创建后 ~20ms |
| 重启应用 / 重建状态项 | 无效——每个新 PID 照样秒拒 |

**最可靠的健康信号是"控制中心有没有为它渲染镜像"**（layer-25、onscreen、同 x 同宽的
ControlCenter 窗口），应用内已实现（`StatusItemController.menuBarHostMirrors`）；
`mirror=false` 基本等价于被拉黑。

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

## 二、根因模型（两层）

1. **触发层（LaunchServices）**：ControlCenter 创建状态项 host 时按 bundle id 查
   LaunchServices。撞上一条**路径已不存在的陈旧注册记录**（死记录）就会触发拉黑。
   本项目的典型来源：`build/VPSQuota.app` 被注册后整目录删除/重建（旧版
   `build-app.sh` 直接 `rm -rf`）、用 `cp -R` 反复安装、删掉安装版。
2. **粘性层（会话态）**：死记录清零后**拉黑仍不解除**。同机受控实验（TokenBar，
   2026-09-14）证明：拉黑按 bundle id 精确命中，与应用代码、路径、签名、
   autosaveName 无关；重启 ControlCenter、`tccutil reset`、`lsregister -f`
   重注册全部无效；ControlCenter 的全部落盘状态查无该 bundle id 痕迹。
   结论：拉黑状态活在重启 ControlCenter 不清的会话层（疑似 WindowServer），
   **注销重登 / 重启是目前唯一有希望的解除手段**（待真机闭环验证）。

## 三、别再踩（实测结论，同机验证）

1. `lsregister -u <path>` **只认路径上真实存在的合法 bundle**。路径已删除时直接失败
   ——对死记录直接 `-u` 永远无效。
2. 清除死记录的**唯一可行方式：原位重建一个最小 stub .app → `-u` → 删掉 stub**。
   应用内实现为 `LaunchServicesJanitor.unregisterRecord`（stub 的 Info.plist 由
   `stubInfoPlist` 生成，CFBundleIdentifier 必须与死记录一致，否则 `-u` 匹配不上）。
3. `lsregister -gc` 清不掉死记录；同 bundle id 在新路径重新注册（`-f`）也挤不掉它。
4. `NSWorkspace.urlsForApplications(withBundleIdentifier:)` 永远找不到死记录
   （它会过滤掉不存在路径），只能解析 `lsregister -dump` 全量输出。
5. 健康/掉线日志行是 `.info` 级（仅驻内存），验证必须先起 `log stream` 现场盯着。
6. `cp -R src /Applications/` 在目标 .app 已存在时会嵌套成
   `/Applications/VPSQuota.app/VPSQuota.app`；装包必须先 `rm -rf` 目标再用 `ditto`。

## 四、应用内自愈机制（代码指引）

判定纯函数在 `macos/Sources/VPSQuotaCore/MenuBar/StatusItemHealth.swift`（有单测），
LS 清理在 `LaunchServicesJanitor.swift`，编排与采样在
`macos/Sources/VPSQuota/UI/StatusItemController.swift` 文末「状态项健康自愈」一节：

- **清理时机**：启动时一次（`startSelfHealing`）+ 每次状态项重建前
  （`rebuildStatusItem`，清理完才重建——拉黑不解除时重建多少次都一样，顺序不能反）。
- **清理范围**：只清**本 bundle id** 且路径已不存在的注册；dump 带 15s 看门狗。
- **失败可见化**：dump 失败 → error 级 `LaunchServices 死记录清理[reason]：dump 执行失败`；
  无死记录 → notice 级 `LaunchServices 注册核对[reason]：无死记录`；
  发现 N 条 → error 级 `发现 N 条，注销 M 条`（M < N 即有失败，含不可写路径清单）。
- **健康判据优先级**（`StatusItemHealth.evaluate`，顺序不可调）：
  `isVisible`（用户意图）→ 存在性/几何 → **镜像信号**（`mirror=false` → `notMirrored`）
  → 窗口服务器注册。信号查不到（nil）时忽略该信号，绝不因查不到判掉线。
- **重建退避**（`RebuildPolicy`）：连续 2 次确认才动手，30/60/120… 秒指数退避，
  单次运行最多 5 次（最后一次先清 autosave 持久化键），连续健康 10 分钟预算清零。
- **探测节奏**：启动校验梯 `launch+2s/5s/15s/60s`，5 分钟心跳，显示器重配置/唤醒后复查；
  面板开着或鼠标按着时跳过（几何不作数）。

## 五、构建与清理纪律（防再触发）

```bash
# 日常构建（脚本会在删旧产物前自动 lsregister -u）
./scripts/build-app.sh

# 构建并替换 /Applications 安装版（先注销旧安装版再删，用 ditto 拷贝，装完即启动）
./scripts/build-app.sh --install

# 删除构建产物——一律走 --clean（先注销构建产物路径再删），别直接 rm
./scripts/build-app.sh --clean
```

`build/VPSQuota.app` 会被 LaunchServices 注册着；直接 `rm` 它就是给
`io.vpsquota.VPSTrafficQuota` 制造新的死记录——下次 ControlCenter 重新评估时
可能再次触发拉黑。卸载安装版同理：先
`lsregister -u /Applications/VPSQuota.app` 再删。

## 六、手动排查与清除手册

### 6.1 盘点死记录（先看再动手）

```bash
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# 本 bundle id 名下所有注册：死链 / 存活
$LSR -dump | awk '/^----/{buf=""} {buf=buf $0 "\n"} /identifier: +io\.vpsquota\.VPSTrafficQuota/{print buf}' \
  | grep -E '^path:' | sed -E 's/^[[:space:]]*path:[[:space:]]+//; s/ \(0x[0-9a-f]+\)$//' | sort -u \
  | while read -r p; do [ -e "$p" ] && echo "[存在]  $p" || echo "[死链]  $p"; done
```

> macOS 自带 BSD sed 不认 `\s`，要写 `[[:space:]]`；否则静默不生效。

### 6.2 清除死记录

- **路径还在的记录**：`$LSR -u <path>` 直接有效。
- **路径已删除的记录**：`-u` 无效，需原位重建最小 stub（应用内已自动化；手动可参照
  `unregisterRecord`：建 `Contents/Info.plist`（CFBundleIdentifier 填
  `io.vpsquota.VPSTrafficQuota`）+ 空 `Contents/MacOS/<可执行名>`，`-u` 后删掉 stub）。
- **`/Volumes/...` 卷路径死记录**：stub 法也够不着（不可写），只能重新挂载对应卷后
  `-u`，或走 6.3 的重手段。

### 6.3 解除已存在的拉黑（按验证程度排序）

| 手段 | 同机实测结果（2026-09-14，TokenBar） |
| :--- | :--- |
| 清 LS 死记录 + 重启应用 | 无效（拉黑是粘性态） |
| 重启 ControlCenter（`killall ControlCenter`，自动重生） | 无效 |
| `tccutil reset All io.vpsquota.VPSTrafficQuota` | 无效 |
| **注销重登 / 重启** | **当前最优假设，待闭环验证**（会话层状态随会话清除） |
| `lsregister -kill -seed -r` 全库重建 | 重手段（影响全局默认应用关联），仅上述全部无效时考虑 |

> 判断拉黑是否已解除：跑第一节的两条命令——ControlCenter 日志不再出现
> `Moving host to blocked list`，且应用侧 `mirror=true`、`verdict=healthy`。

### 6.4 验证流程（装包后必做）

```bash
# 1. 先起日志流（.info 级不落盘，必须现场盯）
command log stream --predicate 'subsystem == "io.vpsquota.VPSTrafficQuota"' --level debug --style compact

# 2. 另开终端：构建 + 安装（一步完成，自带 LS 注销卫生）
./scripts/build-app.sh --install
```

预期日志（健康）：

- `LaunchServices 注册核对[launch]：无死记录`
- `状态项[launch+2s] verdict=healthy … mirror=true`

若出现 `LaunchServices 死记录清理[launch]：发现 N 条，注销 N 条`，说明自愈生效。
若持续 `verdict=detached(notMirrored) … mirror=false` 且 ControlCenter 仍在拉黑，
回到 6.3——大概率需要注销重登/重启一次以清除会话层拉黑；重启后自愈机制会保证
死记录不再积累，问题不再复发。

---
*2026-09-14 · 移植自 TokenBar 的排查结论与自愈实现；如结论被后续验证修正，
先更新本文与 `docs/architecture.md` 对应段落。*
