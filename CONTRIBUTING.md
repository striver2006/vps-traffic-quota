# 参与贡献

欢迎 issue 和 PR。这是一个个人项目，没有繁琐的流程，但有几条约定值得先读一遍 ——
主要是因为**它是双端的**，改动往往需要成对进行。

## 开发环境

| 端 | 要求 |
|---|---|
| macOS | Swift 6+ / macOS 15+（Xcode 命令行工具即可，不需要完整 Xcode 工程） |
| Windows | .NET 8 SDK / Windows 10 1803+（依赖系统自带的 OpenSSH 客户端） |

```bash
# macOS
cd macos
swift build          # 编译全部 target（含 UI 与 CLI）
swift test           # 跑单元测试
./scripts/build-app.sh   # 组装 build/VPSQuota.app
```

```powershell
# Windows
cd windows
dotnet build VpsQuota.sln -c Release
```

### 代码签名与公证

`build-app.sh` 默认用 ad-hoc 签名，够本地跑，但有个副作用：ad-hoc 不内嵌
designated requirement，系统只能按 cdhash 认这个应用，而 cdhash 每次重编都变 ——
钥匙串里「允许本应用访问」的授权随之失效，每轮重编后首次启动都要重新授权一次。

用固定证书签名就没这问题（DR 变成 bundle id + 证书，与二进制内容无关）。
查看本机可用身份，把指纹填进 `macos/scripts/signing-identity.local`
（该文件已 gitignore，格式见同目录 `.example`）：

```bash
security find-identity -v -p codesigning
```

也可以用环境变量临时指定：`CODESIGN_IDENTITY=<指纹> ./scripts/build-app.sh`。

证书类型按用途选：

| 用途 | 证书 | 说明 |
| --- | --- | --- |
| 只想少点授权弹框 | 任意代码签名证书，含自签名 | 钥匙串里用「证书助理」现建一张即可，有效期自定 |
| 要把 .app 发给别人 | **Developer ID Application** | 需付费开发者账号；只有它能通过公证 |

#### 公证

别人下载到的 .app 带 quarantine 标记，没有公证票据会被 Gatekeeper 拦下
（"无法验证开发者"）。自己机器上构建的没有该标记，日常调试不需要公证。

发版时加 `NOTARIZE=1`，脚本会自动补上安全时间戳、上传公证、把票据钉进 bundle：

```bash
NOTARIZE=1 ./scripts/build-app.sh release
```

前提是先存一次公证凭据（每台机器只需一次，密码用 appleid.apple.com 生成的
App 专用密码，不是 Apple ID 登录密码）：

```bash
xcrun notarytool store-credentials "vpsquota-notary" \
  --apple-id <你的 Apple ID> --team-id <你的 Team ID> --password <App 专用密码>
```

profile 名可用 `NOTARY_PROFILE` 覆盖。

> hardened runtime 是常开的，不只在公证时开 —— 公证强制要求它，日常构建也带着，
> 才不会出现"本地跑得好好的、发版才炸"。本项目只用 `Process` 拉起 `/usr/bin/ssh`
> 子进程，不做 JIT、不加载第三方 dylib，无需任何豁免 entitlement。

> `swift test` **只会编译 `VPSQuotaCore` 和测试 target**，
> SwiftUI 应用与 CLI 的编译错误抓不到。提 PR 前请另跑一次 `swift build`。

没有 Windows 机器也可以贡献 —— CI 会在 `windows-latest` 上编译，
这是 Windows 端目前唯一的自动化验证手段（该端尚无测试工程，见下面「有价值的方向」）。

## 目录约定：两端同名同职责

macOS 与 Windows 刻意保持一一对应的目录结构，便于逐个文件对照：

```
Collectors/   采集器，唯一按服务商分叉的地方
Core/         账期、折算、格式化等纯逻辑
Models/       数据结构
Storage/      SQLite、配置、密钥
UI/           界面
```

**改动共用逻辑时请对照着改另一端。** 如果只改得动一端，也可以提 PR 并在描述里说明，
另一端可以后续补 —— 但不要让两端的行为静默地分叉。

跨端一致性由两组测试兜底，它们在 `macos/Tests/` 里：

- `CrossPlatformConfigTests` —— `shared/config.example.json` 能被解析，字段名两端一致
- `SchemaConsistencyTests` —— 代码建出来的表结构与 `shared/schema.sql` 逐列一致

改配置字段或数据库结构时，先改 `shared/` 下的事实源，再改两端代码。

## 新增一家服务商

这是最有价值也最容易上手的扩展方向。架构上**只需要多写一个采集器**：

1. 实现 `Collector` 协议（C# 侧是 `ICollector`），把该服务商的数据转成按天的 rx/tx 序列
2. 在 `ServerConfig` 的 `provider` 枚举里加一项，以及该服务商专用的配置字段
3. 在 `TrafficMonitor.makeCollector` 里接上
4. 设置界面加上对应的输入项
5. 加解析测试（把一份真实响应脱敏后放进 `Tests/VPSQuotaCoreTests/Fixtures/`）

存储、账期切分、口径折算、UI 一行都不用改 —— 如果你发现需要改，
多半说明归一化没做在采集器里，欢迎在 issue 里讨论。

详见 [`docs/architecture.md`](docs/architecture.md)。

## 代码风格

跟着现有代码走就好。几条实际的：

- **注释写「为什么」，不写「是什么」。** 现有代码里的注释密度不低，
  但基本都在解释某个决定的理由或某个坑的来历 —— 保持这个风格。
- **错误信息要能直接用来排查。** SSH 的 stderr 原样透出，不要包装成「连接失败」。
- 面向用户的字符串用中文（与现有界面一致）。
- 不引入新的第三方依赖 —— macOS 端目前零外部依赖，Windows 端只有两个必需的 NuGet 包。
  如果某个功能确实需要依赖，先开 issue 讨论。

## 提交规范

Conventional Commits，subject 用中文：

```
<type>(<scope>): <subject>

feat(macos): 新增起始已用量补偿
fix(windows): 修正托盘图标在高 DPI 下模糊
docs: 补充 Vultr IP 白名单说明
```

类型：`feat` `fix` `docs` `style` `refactor` `perf` `test` `chore` `build` `ci`。
scope 一般是 `macos` / `windows` / `shared`，跨端改动可省略。

## 提 PR 之前

- [ ] `cd macos && swift build && swift test` 全绿
- [ ] 如果改了共用逻辑，另一端也改了（或在描述里说明为什么没改）
- [ ] 如果改了配置字段或 schema，`shared/` 下的事实源也更新了
- [ ] 相关文档同步更新了（README / `docs/`）
- [ ] **没有把真实凭据、真实服务器地址写进代码或测试**
      —— 测试里用 `1.2.3.4` 或 RFC 5737 保留段（`192.0.2.0/24`、`198.51.100.0/24`）

## 有价值的方向

如果想找事做，这几件是目前最缺的：

- **Windows 端的测试工程** —— 该端没有任何自动化测试。至少可以覆盖 config 序列化的
  字段名和 `SqliteStore` 里硬编码的建表 SQL 与 `shared/schema.sql` 的一致性
- **更多服务商** —— 按上面的步骤加一个采集器
- **界面截图** —— README 里一张图都没有
- **告警推送** —— 当前明确列在非目标里，但如果做得足够克制（可关、不吵），值得讨论

## 行为准则

保持基本的尊重和耐心就够了，没有单独的行为准则文件。

## 许可证

提交贡献即表示同意以 [GPL-3.0](LICENSE) 授权。
