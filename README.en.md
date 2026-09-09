<div align="center">

# 📊 VPS Traffic Quota

---

### VPS Traffic Quota Monitor · 流量配额监控

**A cross-platform (macOS / Windows) status-bar tool for monitoring monthly VPS bandwidth usage**

[![CI](https://github.com/striver2006/vps-traffic-quota/actions/workflows/ci.yml/badge.svg)](https://github.com/striver2006/vps-traffic-quota/actions/workflows/ci.yml) [![License](https://img.shields.io/badge/License-GPL--3.0-blue.svg)](LICENSE) ![Platform](https://img.shields.io/badge/Platform-macOS%2015%2B-000000?logo=apple&logoColor=white) ![Platform](https://img.shields.io/badge/Platform-Windows%2010%20%2F%2011-0078D6?logo=windows&logoColor=white) ![Swift](https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white) ![.NET](https://img.shields.io/badge/.NET-8.0-512BD4?logo=dotnet&logoColor=white) ![i18n](https://img.shields.io/badge/i18n-%E4%B8%AD%E6%96%87%20%7C%20English-success)

[简体中文](README.md) | **English**

</div>

---

Monitor monthly bandwidth usage across VPS instances on DMIT and Vultr.
Runs locally in your desktop's status area, collects on a schedule.

- **macOS** — lives in the menu bar; the icon shows how much traffic the server you
  pick has left this period (e.g. `1.94T` / `576G`, or turn the text off and keep just
  the icon).
  Hover over it and the panel floats out. A main window serves as a fallback entry point.
- **Windows** — lives in the system tray; the icon changes color with usage, and
  hovering over it floats out the same panel.

Both platforms are feature-equivalent and share the same config file format
and local database schema.

---

## 🎯 The Problem (它解决什么问题)

DMIT and Vultr each require logging into a separate panel and clicking through every
instance just to see where its bandwidth stands — and the cost of going over is
throttling or suspension.

This tool pulls usage from every provider into one place and extrapolates
"where will this month end up at the current rate", so you find out *before* you
hit the cap rather than after.

## 🔌 Where the Data Comes From (数据从哪来)

| Provider | Method | Notes |
|---|---|---|
| **Vultr** | Official REST API | `GET /v2/instances` for the monthly cap, `GET /v2/instances/{id}/bandwidth` for daily in/out bytes |
| **DMIT** | SSH + `vnstat` | DMIT has no public API, so the only option is reading interface counters over SSH. This path works for **any** server you can SSH into |

Both paths produce the same thing — a per-day rx/tx series — and everything
downstream is identical: split by billing period, convert by metering convention,
store in local SQLite. Adding a provider means writing one more collector, nothing else.

```
Collector (per provider)  →  [per-day rx/tx]
                                   ↓
                    SQLite (upsert, accumulates across runs)
                                   ↓
        Billing period (resetDay) + conversion (meterMode/unitBase)
                                   ↓
              used / remaining / projected / will it exceed
```

Keeping local history matters: the Vultr API only exposes about 30 days and vnstat
keeps daily records for 62 by default, whereas upserting locally lets history
accumulate indefinitely — and a failed collection never blanks out the UI.

---

## 🚀 Quick Start (快速开始)

### 1. Provider side

- Vultr → [`docs/setup-vultr.md`](docs/setup-vultr.md) (create an API key — **mind the IP allowlist**)
- DMIT → [`docs/setup-dmit.md`](docs/setup-dmit.md) (install vnstat, set up key-based SSH)

> Both guides are written in Chinese. The field-by-field
> [config reference](docs/config-reference.md) uses tables and is largely readable
> without it; open an issue in English if anything is unclear.

### 2. macOS

Requires Xcode command line tools (Swift 6+, macOS 15+).

```bash
cd macos
swift test                  # run unit tests
./scripts/build-app.sh      # produces build/VPSQuota.app
open build/VPSQuota.app
```

To install and launch at login:

```bash
cp -R build/VPSQuota.app /Applications/
# System Settings → General → Login Items → add VPSQuota.app
```

On first launch, click the menu bar icon → Settings and fill in your API key and servers.

> Every run of `build-app.sh` produces a different ad-hoc signature, so macOS treats it
> as a different application and prompts for keychain access the first time it reads the
> Vultr API key — choose "Always Allow". This is inherent to not signing with a
> developer certificate and does not affect functionality.

#### Menu bar icon missing?

When the menu bar is crowded — **especially on notched machines** — macOS silently
drops status items that don't fit, with no warning whatsoever. So the app doesn't rely
on the menu bar alone:

- **Dock icon** — on by default; click it to open the main window
- **`open -a VPSQuota`** — opens the main window from a terminal, and is easy to bind
  to Raycast or Alfred

Settings → Appearance switches between menu bar only / Dock only / both (the default).
This preference lives in UserDefaults rather than `config.json` — it's a macOS-specific
UI setting and doesn't belong in the config both platforms share and copy between machines.

#### Diagnostics

When wiring up real credentials, the command line tool is much faster than reading
errors through the GUI:

```bash
swift run vpsquota-cli set-key <VULTR_API_KEY>   # store in keychain
swift run vpsquota-cli vultr-instances           # list instances and allowed_bandwidth
swift run vpsquota-cli probe                     # test connectivity per server
swift run vpsquota-cli refresh                   # collect once and print usage
swift run vpsquota-cli status                    # read local data only, no network
```

### 3. Windows

Requires the .NET 8 SDK and Windows 10 1803+ (uses the built-in OpenSSH client).

```powershell
cd windows
dotnet build VpsQuota.sln -c Release
.\VpsQuota\bin\Release\net8.0-windows\VpsQuota.exe
```

To launch at login, put a shortcut to `VpsQuota.exe` in `shell:startup`
(type that into the Run dialog to open the folder).

---

## ⚙️ Configuration (配置)

Field-by-field reference: [`docs/config-reference.md`](docs/config-reference.md).
Template: [`shared/config.example.json`](shared/config.example.json).

| | Config and data location |
|---|---|
| macOS | `~/Library/Application Support/VPSTrafficQuota/` |
| Windows | `%APPDATA%\VPSTrafficQuota\` |

The format is identical on both platforms — `config.json` can be copied directly.
API keys are not stored in it (macOS uses the keychain, Windows uses DPAPI),
so backing up the config file never leaks credentials.

### ⚠️ Calibrate after first setup

`meterMode` (one-way vs. both directions) and `unitBase` (1024³ vs. 1000³) are the only
two fields the program cannot infer and that cause systematic error when wrong —
the first can be off by a factor of two, the second by 7.4%.

Refresh once, then check the numbers against your provider's panel. See the
[calibration section](docs/config-reference.md) of the config reference.

### Starting mid-period?

vnstat only counts traffic after it started recording, so joining mid-period
understates the current period. Enter the usage shown in your provider's panel under
Settings → Starting usage to make up the difference. The value is bound to the current
billing period and expires automatically at the next one.

### On accuracy

This tool reads bytes actually sent and received by the interface (vnstat) or the
values reported by the provider's API, while billing uses counters on the provider's
switch. The two are usually close but never exactly equal.

**This is an early-warning tool, not a reconciliation tool.** When you're near the cap,
trust the provider's panel.

---

## 📁 Project Layout (项目结构)

```
├── shared/          schema and config template shared by both platforms
├── docs/            setup guides, config reference, architecture, requirements
├── macos/           Swift Package
│   ├── Sources/VPSQuotaCore/    logic + collectors + storage (testable, no UI deps)
│   ├── Sources/VPSQuota/        menu bar app
│   ├── Sources/vpsquota-cli/    diagnostics
│   └── Tests/                   unit tests
└── windows/         .NET 8 WPF tray app
    └── VpsQuota/    same directory names and responsibilities as macOS, for easy comparison
```

The macOS side deliberately splits logic from UI into two targets: `VPSQuotaCore`
pulls in no UI framework, so billing period math, unit conversion and JSON parsing are
all directly unit-testable, and the CLI and GUI share one refresh path.

See [`docs/architecture.md`](docs/architecture.md) for the design rationale and
[`docs/requirements.md`](docs/requirements.md) for scope and explicit non-goals.

## 🤝 Contributing (参与开发)

Issues and PRs are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).
Adding a provider means implementing one collector; nothing else changes.

## 📄 License (许可证)

[GPL-3.0](LICENSE)
