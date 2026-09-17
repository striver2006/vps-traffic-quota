#!/bin/bash
# 把 SwiftPM 产出的可执行文件组装成可双击运行的 .app bundle。
#
# 用法: ./scripts/build-app.sh [release|debug] [--install] [--clean]
#   默认          : 组装 build/VPSQuota.app（日常开发/自用）
#   --install     : 构建后先注销再替换 /Applications 里的安装版并启动。
#                   绝不要用 cp -R 安装（目标已存在时会嵌套成 VPSQuota.app/VPSQuota.app）。
#   --clean       : 先向 LaunchServices 注销构建产物路径再删除，然后退出（不构建）。
#
# 之所以不用 Xcode 工程：SwiftPM 的包描述是纯文本、可 diff、可在命令行完整验证，
# 而菜单栏应用需要的只是一个正确的 bundle 结构和 Info.plist —— 手工组装完全够用。
#
# 删任何被注册过的 .app（构建产物、安装版）之前先 lsregister -u 注销，保持 LaunchServices
# 数据库整洁（否则 `open -a VPSQuota` 可能解析到已删路径，Spotlight 里也会留幽灵条目），
# 所以删除构建产物一律走 --clean，别直接 rm。
#
# 运行调试版一律 `open build/VPSQuota.app`。**不要在 VS Code 等 IDE 的集成终端里直接跑
# swift run 或 .build/debug/VPSQuota** —— 那样进程的"负责进程"是 IDE，菜单栏项会被
# ControlCenter 归到 IDE 名下，随它一起被拉黑（见 docs/TROUBLESHOOTING_菜单栏图标不显示.md）。
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

CONFIGURATION="release"
INSTALL=0
CLEAN=0
UNIVERSAL=1
MAKE_DMG=1
for arg in "$@"; do
    case "$arg" in
        release) CONFIGURATION="release"; UNIVERSAL=1; MAKE_DMG=1 ;;
        debug) CONFIGURATION="debug"; UNIVERSAL=0; MAKE_DMG=0 ;;
        --install) INSTALL=1 ;;
        --clean) CLEAN=1 ;;
        --universal) UNIVERSAL=1 ;;
        --no-universal) UNIVERSAL=0 ;;
        --dmg) MAKE_DMG=1 ;;
        --no-dmg) MAKE_DMG=0 ;;
        *) echo "未知参数: $arg（可用: release debug --install --clean --universal --no-universal --dmg --no-dmg）" >&2; exit 1 ;;
    esac
done

APP_NAME="VPSQuota"
DISPLAY_NAME="VPS 流量"
BUNDLE_ID="io.vpsquota.VPSTrafficQuota"
VERSION="1.0.2"

APP_DIR="$ROOT/build/$APP_NAME.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"
DMG_PATH="$ROOT/build/$APP_NAME.dmg"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
# 删除 .app 之前先注销它的 LaunchServices 注册；路径不存在或 lsregister 不可用时静默跳过
unregister_ls() {
    [ -d "$1" ] && [ -x "$LSREGISTER" ] && "$LSREGISTER" -u "$1" >/dev/null 2>&1 || true
}

if [ "$CLEAN" -eq 1 ]; then
    echo "==> 注销 LaunchServices 注册并删除构建产物..."
    unregister_ls "$APP_DIR"
    rm -rf "$APP_DIR"
    # 图标中间产物与 DMG 不是 bundle、不进 LaunchServices，直接删
    rm -rf "$ROOT/build/$APP_NAME.iconset" "$ROOT/build/$APP_NAME.icns" "$DMG_PATH" "$ROOT/build/dmg-staging"
    echo "==> 清理完成。/Applications 里的安装版未动（要卸载它：注销 + 删除 /Applications/$APP_NAME.app）"
    exit 0
fi

BUILD_ARGS=(-c "$CONFIGURATION" --product "$APP_NAME")
if [ "$UNIVERSAL" -eq 1 ]; then
    BUILD_ARGS+=(--arch arm64 --arch x86_64)
fi

echo "==> 编译（${CONFIGURATION}$( [ "$UNIVERSAL" -eq 1 ] && echo " · Universal arm64+x86_64" || echo "" )）"
swift build "${BUILD_ARGS[@]}"
BIN_PATH="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"

echo "==> 生成图标"
# 图标用代码画（scripts/make-icon.swift），不往仓库里塞二进制资源：
# 配色可调、可 diff，也不依赖任何设计工具。
swift "$ROOT/scripts/make-icon.swift" "$ROOT/build"
iconutil -c icns "$ROOT/build/VPSQuota.iconset" -o "$ROOT/build/VPSQuota.icns"

echo "==> 组装 $APP_DIR"
# 先注销再删：万一本次构建中途失败收场，也不会在 LaunchServices 里留下指向本路径的注册
unregister_ls "$APP_DIR"
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

echo "==> 代码签名"
# 必须用固定的开发者证书签，不能用 ad-hoc（--sign -）。
#
# 钥匙串里「允许本应用访问」那条 ACL 记的是应用的 designated requirement。
# ad-hoc 签名不内嵌任何 requirement，DR 只能退化成 cdhash —— 而 cdhash 随二进制
# 逐字节变化，每次重编都是一个"新应用"，ACL 立刻失效，于是每次重编后启动
# 都被钥匙串弹框拦住要重新授权。用证书签名后 DR 变成
# 「bundle id + Apple 根 + 这张证书」，重编不影响，授权一次就一直有效。
#
# 用谁的证书不写死在这里：这是公开仓库，证书指纹和持有人姓名都不该进版本库，
# 而且别人克隆下来也用不了我的证书。按优先级取，取到哪个算哪个：
#   1. 环境变量 CODESIGN_IDENTITY
#   2. scripts/signing-identity.local —— 本机私有，已在 .gitignore 里
#   3. "-"，即 ad-hoc。缺证书不该让构建失败，
#      代价只是回到"每次重编都要重新授权钥匙串"。
#
# 值建议填证书的 SHA-1 而不是证书名：钥匙串里同名证书往往不止一张
# （旧的过期/吊销的还留着），按名字匹配 codesign 会报 ambiguous 直接失败。
# 用 `security find-identity -v -p codesigning` 查看本机可用身份。
IDENTITY_FILE="$ROOT/scripts/signing-identity.local"
if [ -z "${CODESIGN_IDENTITY:-}" ] && [ -f "$IDENTITY_FILE" ]; then
    # 取第一个非空非注释行
    CODESIGN_IDENTITY="$(grep -vE '^[[:space:]]*(#|$)' "$IDENTITY_FILE" | head -1 | tr -d '[:space:]')"
fi
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

# 先把输出接进变量再匹配，不要写成 `... | grep -q`：本脚本开了 pipefail，
# 而 grep -q 一匹配就退出，上游命令随即吃到 SIGPIPE(141)，
# 整条管道被判成失败 —— 匹配成功反而进错误分支，这里就会误判成
# "证书找不到" 而静默退回 ad-hoc 签名。
AVAILABLE_IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
if [ "$CODESIGN_IDENTITY" != "-" ] \
    && ! grep -q "$CODESIGN_IDENTITY" <<<"$AVAILABLE_IDENTITIES"; then
    echo "    ⚠️  本机找不到指定的签名身份，退回 ad-hoc 签名"
    echo "       （每次重编后首次启动都会被钥匙串弹框拦一次）"
    CODESIGN_IDENTITY="-"
fi
if [ "$CODESIGN_IDENTITY" = "-" ]; then
    echo "    ad-hoc 签名。想免掉重复授权，见 scripts/signing-identity.local.example"
fi

# 没有嵌套 bundle（SwiftPM 这个包不产出 .bundle 资源），不需要也不该用 --deep。
#
# hardened runtime 常开，不只在公证时开：公证强制要求它，日常构建也带着，
# 才不会出现"本地跑得好好的、发版才炸"。这个应用只是用 Process 拉起
# /usr/bin/ssh 子进程，不做 JIT、不加载第三方 dylib，无需任何豁免 entitlement。
SIGN_ARGS=(--force --options runtime --sign "$CODESIGN_IDENTITY")
if [ "${NOTARIZE:-0}" = "1" ]; then
    # 公证要求签名里带安全时间戳，这一步必须联网。
    SIGN_ARGS+=(--timestamp)
else
    # 本地自用不公证：跳过时间戳，构建不必联网，也快一点。
    SIGN_ARGS+=(--timestamp=none)
fi

codesign "${SIGN_ARGS[@]}" "$APP_DIR"
codesign --verify --strict "$APP_DIR"

if [ "$CODESIGN_IDENTITY" != "-" ]; then
    echo "    签名身份：$(codesign -dvv "$APP_DIR" 2>&1 | grep '^Authority=' | head -1 | cut -d= -f2-)"
fi

# ── 制作 DMG 安装包 ─────────────────────────────
if [ "$MAKE_DMG" -eq 1 ]; then
    echo "==> 制作 DMG 安装包"
    DMG_STAGING="$ROOT/build/dmg-staging"
    rm -rf "$DMG_STAGING" "$DMG_PATH"
    mkdir -p "$DMG_STAGING"

    ditto "$APP_DIR" "$DMG_STAGING/$APP_NAME.app"
    ln -s /Applications "$DMG_STAGING/Applications"

    hdiutil create \
        -volname "$DISPLAY_NAME" \
        -srcfolder "$DMG_STAGING" \
        -ov \
        -format UDZO \
        "$DMG_PATH"
    rm -rf "$DMG_STAGING"

    if [ "$CODESIGN_IDENTITY" != "-" ]; then
        echo "    签名 DMG"
        codesign "${SIGN_ARGS[@]}" "$DMG_PATH"
        codesign --verify --strict "$DMG_PATH"
    fi
    echo "    已生成 DMG：$DMG_PATH"
fi

# ── 公证（仅 NOTARIZE=1）────────────────────────
# 只有要把 .app / .dmg 发给别人时才需要：别人下载到的包带 quarantine 标记，
# 没有公证票据就会被 Gatekeeper 拦下（"无法验证开发者"）。
# 自己机器上构建出来的没有该标记，日常调试用不着，也就不必每次等这几十秒。
if [ "${NOTARIZE:-0}" = "1" ]; then
    echo "==> 公证"
    NOTARY_PROFILE="${NOTARY_PROFILE:-vpsquota-notary}"

    # 公证只认 Developer ID Application，Apple Development 会被直接拒，
    # 提前拦下来，省得白等一轮上传。
    SIGN_INFO="$(codesign -dvv "$APP_DIR" 2>&1 || true)"
    if ! grep -q "^Authority=Developer ID Application" <<<"$SIGN_INFO"; then
        echo "    ❌ 当前签名不是 Developer ID Application，公证必然失败。" >&2
        echo "       用 security find-identity -v -p codesigning 找到 Developer ID 那张，" >&2
        echo "       把指纹填进 scripts/signing-identity.local。" >&2
        exit 1
    fi

    if [ "$MAKE_DMG" -eq 1 ] && [ -f "$DMG_PATH" ]; then
        SUBMIT_TARGET="$DMG_PATH"
    else
        ZIP="$ROOT/build/$APP_NAME-notarize.zip"
        rm -f "$ZIP"
        ditto -c -k --keepParent "$APP_DIR" "$ZIP"
        SUBMIT_TARGET="$ZIP"
    fi

    set +e
    SUBMIT_LOG="$(xcrun notarytool submit "$SUBMIT_TARGET" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)"
    SUBMIT_RC=$?
    set -e
    echo "$SUBMIT_LOG"
    [ "$SUBMIT_TARGET" != "$DMG_PATH" ] && rm -f "$SUBMIT_TARGET"

    if [ "$SUBMIT_RC" -ne 0 ] || ! grep -q "status: Accepted" <<<"$SUBMIT_LOG"; then
        echo "    ❌ 公证未通过。" >&2
        SUBMISSION_ID="$(grep -m1 -E '^ *id: ' <<<"$SUBMIT_LOG" | awk '{print $2}')"
        if [ -n "$SUBMISSION_ID" ]; then
            xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" >&2 || true
        fi
        echo "       若报的是凭据问题，先存一次凭据（每台机器只需一次）：" >&2
        echo "         xcrun notarytool store-credentials \"$NOTARY_PROFILE\" \\" >&2
        echo "           --apple-id <你的 Apple ID> --team-id <你的 Team ID> \\" >&2
        echo "           --password <App 专用密码，appleid.apple.com 生成>" >&2
        exit 1
    fi

    # 把票据钉进 bundle 和 DMG
    xcrun stapler staple "$APP_DIR"
    xcrun stapler validate "$APP_DIR"
    if [ "$MAKE_DMG" -eq 1 ] && [ -f "$DMG_PATH" ]; then
        xcrun stapler staple "$DMG_PATH"
        xcrun stapler validate "$DMG_PATH"
    fi
    echo "    Gatekeeper：$(spctl -a -vv "$APP_DIR" 2>&1 | tail -1)"
fi

# ── 安装（仅 --install）────────────────────────
# 替换 /Applications 里的安装版。三个纪律：
# 1. 先退出正在运行的实例（文件被换掉时旧进程仍占着旧 inode，行为不可预期）；
# 2. 先 lsregister -u 再删旧安装版，不留指向已删路径的注册；
# 3. 必须用 ditto 而不是 cp -R —— cp -R 在目标 .app 已存在时会嵌套成
#    /Applications/VPSQuota.app/VPSQuota.app。
if [ "$INSTALL" -eq 1 ]; then
    echo "==> 安装到 /Applications"
    INSTALLED="/Applications/$APP_NAME.app"
    if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
        echo "    先退出正在运行的 $APP_NAME"
        killall "$APP_NAME" 2>/dev/null || true
        sleep 1
    fi
    unregister_ls "$INSTALLED"
    rm -rf "$INSTALLED"
    ditto "$APP_DIR" "$INSTALLED"
    open -a "$INSTALLED"
    echo "    已启动。健康日志（另开终端）："
    echo "      command log stream --predicate 'subsystem == \"$BUNDLE_ID\"' --level debug --style compact"
fi

echo ""
echo "✅ 已生成：$APP_DIR"
echo ""
echo "安装到应用：./scripts/build-app.sh --install   （别用 cp -R，目标已存在时会嵌套）"
echo "删除构建产物：./scripts/build-app.sh --clean    （先注销 LaunchServices 再删）"
echo "运行调试版：  open build/VPSQuota.app            （别在 IDE 集成终端里直接跑可执行文件）"
echo "开机自启：  应用内「设置 → 启动 → 登录时启动」"
