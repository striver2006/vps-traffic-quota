#!/bin/bash
# 辅助脚本：一键将本地 Apple Developer ID 证书配置到 GitHub Actions Secrets，
# 从而实现 push tag 时 GitHub CI 全自动签名并发布 Release。
#
# 前置条件：
#   1. 在「钥匙串访问」(Keychain Access) 中找到 Developer ID Application 证书
#   2. 右键 -> 导出为 .p12 文件，设置一个导出密码
#   3. 执行本脚本：./macos/scripts/setup-ci-secrets.sh <path-to-p12-file>
set -euo pipefail

if ! command -v gh >/dev/null 2>&1; then
    echo "❌ 未检测到 GitHub CLI (gh)，请先安装: brew install gh" >&2
    exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
    echo "❌ GitHub CLI 未登录，请先执行: gh auth login" >&2
    exit 1
fi

if [ "$#" -lt 1 ]; then
    echo "用法: $0 <证书.p12路径> [签名身份名称]"
    echo ""
    echo "示例: $0 ~/Desktop/developer_id.p12 \"Developer ID Application: Zhenbo Chen (B8QGM665TS)\""
    exit 1
fi

P12_PATH="$1"
IDENTITY="${2:-Developer ID Application: Zhenbo Chen (B8QGM665TS)}"

if [ ! -f "$P12_PATH" ]; then
    echo "❌ 找不到文件: $P12_PATH" >&2
    exit 1
fi

read -rsp "请输入 .p12 证书导出时设置的密码: " P12_PASSWORD
echo ""

echo "==> 正在配置 GitHub Secrets..."
base64 -i "$P12_PATH" | gh secret set MACOS_CERTIFICATE
echo "$P12_PASSWORD" | gh secret set MACOS_CERTIFICATE_PWD
echo "$IDENTITY" | gh secret set MACOS_CERTIFICATE_IDENTITY

echo "✅ 配置完成！已成功写入以下 GitHub Secrets："
echo "   - MACOS_CERTIFICATE"
echo "   - MACOS_CERTIFICATE_PWD"
echo "   - MACOS_CERTIFICATE_IDENTITY"
echo ""
echo "以后只需在发布新版本时打标签推送："
echo "   git tag -a v1.0.4 -m 'Release v1.0.4'"
echo "   git push origin v1.0.4"
echo "GitHub Actions 将全自动编译、签名并发布包含 macOS (DMG/ZIP) 与 Windows (EXE/ZIP) 的正式 Release！"
