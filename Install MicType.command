#!/bin/bash
#
# MicType installer — build from source and install
# MicType 安装脚本——从源码编译并安装
# Requires: macOS 15+, Apple Silicon, full Xcode
#
set -u

cd "$(dirname "$0")/MicType" || { echo "MicType directory not found / 找不到 MicType 目录"; exit 1; }

# 双语输出：跟随系统语言
SYS_LANG=$(defaults read -g AppleLanguages 2>/dev/null | sed -n '2p')
case "$SYS_LANG" in
    *zh*) ZH=1 ;;
    *)    ZH=0 ;;
esac
t() { if [ "$ZH" = "1" ]; then printf "%s" "$1"; else printf "%s" "$2"; fi; }

bold()  { printf "\033[1m%s\033[0m\n" "$1"; }
green() { printf "\033[32m%s\033[0m\n" "$1"; }
red()   { printf "\033[31m%s\033[0m\n" "$1"; }
step()  { echo; bold "==> $1"; }

fail() {
    echo
    red "✗ $1"
    echo
    echo "$(t "把上面的报错信息发给开发助手即可。按任意键退出…" "Send the error above to your dev assistant. Press any key to exit…")"
    read -n 1 -s || true
    exit 1
}

echo
bold "╔══════════════════════════════════════════╗"
bold "║   MicType $(t "安装" "Installer")                          ║"
bold "╚══════════════════════════════════════════╝"


ARCH=$(uname -m)
[ "$ARCH" = "arm64" ] || fail "$(t "需要 Apple Silicon" "Apple Silicon required")"

# ── 1. Xcode & Metal toolchain ─────────────────────
step "1/4 $(t "检查 Xcode" "Checking Xcode")"
DEV_DIR=$(xcode-select -p 2>/dev/null || echo "")
if [[ "$DEV_DIR" != *"Xcode.app"* ]]; then
    if [ -d "/Applications/Xcode.app" ]; then
        echo "  $(t "切换默认工具链，需要开机密码：" "Switching default toolchain — your login password is required:")"
        sudo xcode-select -s /Applications/Xcode.app/Contents/Developer || fail "$(t "切换失败" "Switch failed")"
    else
        fail "$(t "未找到 /Applications/Xcode.app" "/Applications/Xcode.app not found")"
    fi
fi
xcodebuild -version >/dev/null 2>&1 || fail "$(t "xcodebuild 不可用" "xcodebuild unavailable")"
if ! xcrun metal --version >/dev/null 2>&1; then
    echo "  $(t "下载 Metal 工具链（一次性，约 2-4GB）…" "Downloading the Metal toolchain (one-time, ~2-4 GB)…")"
    xcodebuild -downloadComponent MetalToolchain || fail "$(t "Metal 工具链下载失败" "Metal toolchain download failed")"
fi
[ -f "Resources/QwenTokenizer/tokenizer.json" ] || fail "$(t "缺少分词器：先运行 scripts/Generate Qwen Tokenizer.command" "Tokenizer missing — run scripts/Generate Qwen Tokenizer.command first")"
green "  ✓ $(t "构建环境就绪" "Build environment ready")"

# ── 2. Build ───────────────────────────────────────
step "2/4 $(t "编译 MicType（首次 5-15 分钟）" "Building MicType (first build takes 5-15 min)")"
DERIVED=".xcbuild"
if xcodebuild -scheme MicType \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED" \
    build 2>&1 | tee build.log | grep -E "^(\\*\\* BUILD|error:)" ; then
    :
fi
PRODUCTS="$DERIVED/Build/Products/Release"
BIN="$PRODUCTS/MicType"
[ -f "$BIN" ] || fail "$(t "编译失败。请把 MicType/build.log 最后 50 行发给开发助手。" "Build failed. Send the last 50 lines of MicType/build.log to your dev assistant.")"
green "  ✓ $(t "编译成功" "Build succeeded")"

# ── 3. Package ─────────────────────────────────────
step "3/4 $(t "打包应用" "Packaging the app")"
STAGE=$(mktemp -d)
APP="$STAGE/MicType.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/MicType"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# MLX/tokenizer resource bundles (incl. Metal shaders) must ship with the app
if compgen -G "$PRODUCTS/*.bundle" > /dev/null; then
    for B in "$PRODUCTS"/*.bundle; do
        ditto "$B" "$APP/Contents/Resources/$(basename "$B")"
    done
fi
mkdir -p "$APP/Contents/Resources/QwenTokenizer"
cp "Resources/QwenTokenizer/tokenizer.json" "$APP/Contents/Resources/QwenTokenizer/"

# 自带的 4 个提示音（替掉系统的 Pop/Glass/Basso/Bottle）。
# 缺了 App 会退回系统音，所以这里不让它阻断安装。
if [ -d "Resources/Sounds" ]; then
    mkdir -p "$APP/Contents/Resources/Sounds"
    cp Resources/Sounds/*.wav "$APP/Contents/Resources/Sounds/"
fi

# 内置的模型目录（model-catalog.json）：断网 / 没缓存时的模型清单来源。
# 缺了 App 会退回代码里的字面表，所以同样不阻断安装。
if [ -f "Resources/model-catalog.json" ]; then
    cp Resources/model-catalog.json "$APP/Contents/Resources/model-catalog.json"
fi

# App icon: Icon Composer source -> Assets.car + icns (macOS 26 otherwise shows a grey tile)
bash ../scripts/build-app-icon.sh "$APP" || true

find "$APP" \( -name "._*" -o -name ".DS_Store" \) -delete 2>/dev/null || true
xattr -rc "$APP" 2>/dev/null || true
# 签名身份：优先用稳定的 Developer ID。macOS 把「辅助功能」授权绑定到签名身份，
# ad-hoc(-s -) 每次构建身份都变 → 升级后旧授权失效，必须到系统设置里删了重加。
# Developer ID 身份稳定 → 同身份升级授权自动延续。无证书才退回 ad-hoc。
SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Developer ID Application" | sed -E 's/^[^"]*"([^"]*)".*$/\1/')
if [ -n "$SIGN_ID" ]; then
    codesign --force -s "$SIGN_ID" "$APP" || fail "$(t "签名失败" "Code signing failed")"
    STABLE_SIGN=1
    echo "  $(t "已用 Developer ID 签名，授权将跨升级保留" "Signed with Developer ID — authorization persists across updates")"
else
    codesign --force -s - "$APP" || fail "$(t "签名失败" "Code signing failed")"
    STABLE_SIGN=0
    echo "  $(t "无 Developer ID 证书，ad-hoc 签名（每次升级需重新授权辅助功能）" "No Developer ID cert — ad-hoc signed (re-grant Accessibility after each update)")"
fi
codesign --verify --deep "$APP" || fail "$(t "签名校验未通过" "Signature verification failed")"
green "  ✓ $(t "打包完成" "Packaging complete")"

# ── 4. Install ─────────────────────────────────────
step "4/4 $(t "安装到 /Applications" "Installing to /Applications")"
pkill -x MicType 2>/dev/null || true
sleep 0.5
DEST="/Applications/MicType.app"
rm -rf "$DEST" 2>/dev/null
if ! ditto "$APP" "$DEST" 2>/dev/null; then
    DEST="$HOME/Applications/MicType.app"
    mkdir -p "$HOME/Applications"
    rm -rf "$DEST"
    ditto "$APP" "$DEST" || fail "$(t "无法复制到应用程序文件夹" "Could not copy to the Applications folder")"
fi
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
touch "$DEST" 2>/dev/null || true
# 仅 ad-hoc 签名（身份不稳定、旧授权失效又看似还在）才清掉强制重授；
# Developer ID 身份稳定，reset 反而会白白丢掉用户已有授权。
if [ "${STABLE_SIGN:-0}" != "1" ]; then
    tccutil reset Accessibility com.ligen.mictype >/dev/null 2>&1 || true
fi
green "  ✓ $(t "已安装：" "Installed: ")$DEST"

open "$DEST"

echo
bold "🎉 $(t "MicType 安装完成！接下来：" "MicType installed! Next steps:")"
echo
if [ "${STABLE_SIGN:-0}" = "1" ]; then
    echo "  1. $(t "授权【辅助功能】：系统设置 → 隐私与安全性 → 辅助功能（从旧 ad-hoc 版切过来需先删旧条目再加一次；之后升级自动保留）" "Grant Accessibility: System Settings → Privacy & Security → Accessibility (upgrading from an old ad-hoc build: remove the old entry, add once; future updates keep it)")"
else
    echo "  1. $(t "重新授权【辅助功能】：系统设置 → 隐私与安全性 → 辅助功能（已有条目先删再加）" "Re-grant Accessibility: System Settings → Privacy & Security → Accessibility (remove the old entry, then add again)")"
fi
echo "  2. $(t "首次使用：设置 → 识别 → 下载模型（约 860MB，一次性）" "First run: Settings → Recognition → Download Model (~860 MB, one-time)")"
echo "  3. $(t "轻点右⌥听写；按住右⌥说指令（改写/回复/草拟/翻译）" "Tap Right-Option to dictate; hold it to speak commands (rewrite/reply/draft/translate)")"
echo
echo "$(t "按任意键关闭本窗口…" "Press any key to close…")"
read -n 1 -s || true
