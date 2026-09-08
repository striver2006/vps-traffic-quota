#!/bin/bash
# 把 SwiftPM 产出的可执行文件组装成可双击运行的 .app bundle。
#
# 之所以不用 Xcode 工程：SwiftPM 的包描述是纯文本、可 diff、可在命令行完整验证，
# 而菜单栏应用需要的只是一个正确的 bundle 结构和 Info.plist —— 手工组装完全够用。
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

CONFIGURATION="${1:-release}"
APP_NAME="VPSQuota"
DISPLAY_NAME="VPS 流量"
BUNDLE_ID="io.vpsquota.VPSTrafficQuota"
VERSION="1.0.0"

APP_DIR="$ROOT/build/$APP_NAME.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"

echo "==> 编译（${CONFIGURATION}）"
swift build -c "$CONFIGURATION" --product "$APP_NAME"
BIN_PATH="$(swift build -c "$CONFIGURATION" --product "$APP_NAME" --show-bin-path)"

echo "==> 生成图标"
# 图标用代码画（scripts/make-icon.swift），不往仓库里塞二进制资源：
# 配色可调、可 diff，也不依赖任何设计工具。
swift "$ROOT/scripts/make-icon.swift" "$ROOT/build"
iconutil -c icns "$ROOT/build/VPSQuota.iconset" -o "$ROOT/build/VPSQuota.icns"

echo "==> 组装 $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BIN_PATH/$APP_NAME" "$MACOS_DIR/$APP_NAME"
cp "$ROOT/build/VPSQuota.icns" "$RESOURCES_DIR/VPSQuota.icns"

# 随包带上文档，供「帮助 → 使用说明」打开。
# 有 pandoc 就转成带样式的 HTML（表格、代码块才能正常呈现），
# 没有则退回原始 Markdown —— 构建不该因为缺一个可选工具就失败。
DOCS_SRC="$ROOT/.."
if command -v pandoc >/dev/null 2>&1; then
    echo "==> 渲染文档（pandoc）"
    mkdir -p "$RESOURCES_DIR/docs"

    render_doc() {
        local src="$1" out="$2"
        # 标题取正文第一个一级标题，没有就用文件名
        local title
        title="$(grep -m1 '^# ' "$src" | sed 's/^# //')"
        [ -n "$title" ] || title="$(basename "$src" .md)"

        pandoc "$src" \
            --from=gfm \
            --to=html5 \
            --standalone \
            --metadata title="$title" \
            --include-in-header="$ROOT/scripts/doc-header.html" \
            --output="$out"

        # 文档之间互相引用的是 .md，包内换成了 .html，链接得跟着改写（保留 #锚点）
        sed -i '' -E 's/href="([^"]*)\.md(#[^"]*)?"/href="\1.html\2"/g' "$out"
    }

    render_doc "$DOCS_SRC/README.md" "$RESOURCES_DIR/README.html"
    for md in "$DOCS_SRC/docs/"*.md; do
        render_doc "$md" "$RESOURCES_DIR/docs/$(basename "${md%.md}").html"
    done

    # README 里引用了它，一并带上，链接才不会断
    mkdir -p "$RESOURCES_DIR/shared"
    cp "$DOCS_SRC/shared/config.example.json" "$RESOURCES_DIR/shared/"
else
    echo "==> 未找到 pandoc，改为随包分发原始 Markdown"
    cp "$DOCS_SRC/README.md" "$RESOURCES_DIR/README.md"
    cp -R "$DOCS_SRC/docs" "$RESOURCES_DIR/docs"
fi

# 声明简体中文本地化：没有这个目录时，macOS 会把 Edit/View/Window 等
# 标准菜单显示成英文，与中文的应用名对不上。
mkdir -p "$RESOURCES_DIR/zh-Hans.lproj"
touch "$RESOURCES_DIR/zh-Hans.lproj/InfoPlist.strings"

# SwiftPM 会把资源打成 .bundle 放在 bin 目录下，需要一并搬进 Resources。
for bundle in "$BIN_PATH"/*.bundle; do
    [ -e "$bundle" ] || continue
    cp -R "$bundle" "$RESOURCES_DIR/"
done

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$DISPLAY_NAME</string>
    <key>CFBundleDisplayName</key><string>$DISPLAY_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>VPSQuota</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>zh-Hans</string>
    </array>
    <!-- 菜单栏常驻应用：不在 Dock 显示图标，也不占用程序坞空间 -->
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>Copyright © 2026 ChenZhenbo. Licensed under GPL-3.0.</string>
</dict>
</plist>
PLIST

echo "==> 临时签名"
# 本地自用无需开发者证书；ad-hoc 签名足以让 Keychain 访问在重启后保持稳定。
codesign --force --deep --sign - "$APP_DIR"

echo ""
echo "✅ 已生成：$APP_DIR"
echo ""
echo "运行：      open \"$APP_DIR\""
echo "安装到应用：cp -R \"$APP_DIR\" /Applications/"
echo "开机自启：  系统设置 → 通用 → 登录项 → 添加 $APP_NAME.app"
