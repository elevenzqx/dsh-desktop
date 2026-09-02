#!/usr/bin/env bash
# DSH Desktop 构建脚本 —— 编译 Swift 菜单栏应用并打包为 .app
# 用法: ./build.sh       产物: build/DSHDesktop.app
# 安装: cp -R build/DSHDesktop.app /Applications/
set -euo pipefail
cd "$(dirname "$0")"

APP="build/DSHDesktop.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"

echo "▶ 清理并准备目录"
rm -rf build
mkdir -p "$MACOS" "$RES"

# ── 侧边栏官网图标资源 ──
if [ -d Resources/icons ]; then
  mkdir -p "$RES/icons"
  cp Resources/icons/* "$RES/icons/"
  echo "▶ 打包侧边栏官网图标: $(ls Resources/icons | wc -l | tr -d ' ') 个"
fi

# ── 解析 dsh / node 绝对路径（Finder 启动时 PATH 很窄，必须写死）──
resolve_tool() {
  local name="$1" bin=""
  bin="$(command -v "$name" 2>/dev/null || true)"
  if [ -n "$bin" ]; then echo "$bin"; return; fi
  for d in /usr/local/bin /opt/homebrew/bin /opt/local/bin /usr/bin /bin; do
    if [ -x "$d/$name" ]; then echo "$d/$name"; return; fi
  done
  echo ""
}

NODE="$(resolve_tool node)"
DSH="$(resolve_tool dsh)"
BIN_DIR="$(dirname "$NODE")"

if [ -z "$NODE" ] || [ -z "$DSH" ]; then
  echo "✗ 未找到 node 或 dsh，请先在终端确认: which node dsh"
  exit 1
fi
echo "▶ 使用工具路径:"
echo "   node = $NODE"
echo "   dsh  = $DSH"

# ── 编译主程序 ──
echo "▶ 编译主程序 (swiftc)"
mkdir -p build/swift-module-cache
swiftc -O -swift-version 5 \
  -module-cache-path "$PWD/build/swift-module-cache" \
  -o "$MACOS/DSHDesktop" Sources/main.swift Sources/browser.swift
echo "   完成: $MACOS/DSHDesktop"

# ── 生成应用图标 ──
echo "▶ 生成图标"
swiftc -O -swift-version 5 \
  -module-cache-path "$PWD/build/swift-module-cache" \
  -o build/icon-gen Sources/icon-gen.swift
./build/icon-gen build/icon.png

ICONSET="build/DSHDesktop.iconset"
mkdir -p "$ICONSET"
while IFS= read -r spec; do
  set -- $spec
  sips -z "$2" "$2" build/icon.png --out "$ICONSET/$1" >/dev/null
done <<'SIZES'
icon_16x16.png 16
icon_16x16@2x.png 32
icon_32x32.png 32
icon_32x32@2x.png 64
icon_128x128.png 128
icon_128x128@2x.png 256
icon_256x256.png 256
icon_256x256@2x.png 512
icon_512x512.png 512
icon_512x512@2x.png 1024
SIZES
iconutil -c icns "$ICONSET" -o "$RES/DSHDesktop.icns"
echo "   完成: $RES/DSHDesktop.icns"

# ── Info.plist（LSUIElement：纯菜单栏应用，不占 Dock）──
cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>DSHDesktop</string>
  <key>CFBundleIdentifier</key><string>local.dsh.desktop</string>
  <key>CFBundleName</key><string>DSH Desktop</string>
  <key>CFBundleDisplayName</key><string>DSH Desktop</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleIconFile</key><string>DSHDesktop</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>DSH Desktop — dsh Web 极简启动器</string>
</dict>
</plist>
PLIST
echo "   完成: $CONTENTS/Info.plist"

# ── 工具路径配置（运行时直接从 Bundle 读取）──
cat > "$RES/dsh-paths.json" <<JSON
{"node":"$NODE","dsh":"$DSH","binDir":"$BIN_DIR"}
JSON
echo "   完成: $RES/dsh-paths.json"

# ── 签名（ad-hoc，本机可运行，无需开发者账号）──
codesign --force --deep -s - "$APP" >/dev/null 2>&1
echo "▶ 签名完成 (ad-hoc)"

echo ""
echo "✔ 构建完成 → $PWD/$APP"
echo "  安装:   cp -R \"$APP\" /Applications/"
echo "  运行:   open /Applications/DSHDesktop.app   （或直接打开 build/DSHDesktop.app）"