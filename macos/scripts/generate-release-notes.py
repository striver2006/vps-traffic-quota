#!/usr/bin/env python3
import os
import re
import sys

def main():
    tag_name = sys.argv[1] if len(sys.argv) > 1 else "v1.0.0"
    version = tag_name.lstrip("v")
    header = """### 📦 安装包与分发说明

- **macOS**：
  - `VPSQuota-macos.dmg`：Universal 2 通用二进制安装包（原生支持 Apple Silicon 与 Intel 双架构），内置 `/Applications` 快捷替身，拖拽即可安装。
  - `VPSQuota-macos.zip`：便携版 zip 包。

- **Windows**：
  - `VPSQuota-Setup-win-x64.exe`：Intel / AMD 64位 Windows 安装包，自包含 .NET 8 运行时，无需单独安装依赖，免管理员提权（安装至用户目录）。
  - `VPSQuota-Setup-win-arm64.exe`：ARM64 架构原生安装包（支持 Surface Pro、骁龙 X Elite 等 Windows on ARM 设备）。
  - `VPSQuota-win-x64.zip` / `VPSQuota-win-arm64.zip`：便携绿色解压即用包。

---

"""
    notes = header
    changelog_path = os.path.join(os.path.dirname(__file__), "..", "..", "CHANGELOG.md")
    if os.path.exists(changelog_path):
        with open(changelog_path, "r", encoding="utf-8") as f:
            content = f.read()
        pattern = r"## \[" + re.escape(version) + r"\].*?\n(.*?)(?=\n## \[|\Z)"
        match = re.search(pattern, content, re.DOTALL)
        if match:
            notes += match.group(1).strip() + "\n"

    print(notes)

if __name__ == "__main__":
    main()
