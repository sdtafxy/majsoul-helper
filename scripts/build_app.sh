#!/bin/bash
# 构建 MajsoulHelper.app
#
# 两个本机特有的坑，脚本里已经处理掉：
#  1) `xcode-select` 指向的是 CommandLineTools，而 SwiftUI 的属性包装器（@State 等）
#     已经改成宏实现，宏插件 SwiftUIMacros 只随 Xcode 提供 —— 不显式指 DEVELOPER_DIR
#     就会报 "external macro implementation type 'SwiftUIMacros.StateMacro' could not be found"。
#  2) SwiftPM 的新构建引擎（swiftbuild）在本机报 "Unknown error parsing property list"，
#     所以这里显式退回 `--build-system native`。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# ---------- 1. 定位 Xcode ----------
if [ -z "${DEVELOPER_DIR:-}" ]; then
  for X in /Applications/Xcode.app /Applications/Xcode-beta.app; do
    if [ -d "$X" ]; then export DEVELOPER_DIR="$X/Contents/Developer"; break; fi
  done
fi
if [ -z "${DEVELOPER_DIR:-}" ]; then
  echo "找不到 Xcode。SwiftUI 的宏插件需要 Xcode，光有 CommandLineTools 编不过。" >&2
  exit 1
fi
echo "DEVELOPER_DIR = $DEVELOPER_DIR"

CONFIG="${CONFIG:-release}"
APP="$ROOT/dist/MajsoulHelper.app"
BUNDLE_ID="com.feng.majsoulhelper"

# ---------- 2. 编译 ----------
echo "=== 编译 ($CONFIG) ==="
swift build -c "$CONFIG" --build-system native

BIN="$ROOT/.build/$CONFIG/MajsoulHelper"
[ -x "$BIN" ] || { echo "编译产物不存在: $BIN" >&2; exit 1; }

# ---------- 3. 图标（没有才生成，避免每次构建都跑一遍） ----------
ICNS="$ROOT/Resources/AppIcon.icns"
MASTER="$ROOT/Resources/AppIcon-1024.png"
if [ ! -f "$ICNS" ]; then
  echo "=== 生成图标 ==="
  PY=""
  for CAND in \
      "$HOME/.workbuddy/binaries/python/envs/default/bin/python" \
      "$(command -v python3 || true)"; do
    if [ -n "$CAND" ] && [ -x "$CAND" ] && "$CAND" -c "import PIL" 2>/dev/null; then PY="$CAND"; break; fi
  done
  if [ -z "$PY" ]; then
    echo "跳过图标：找不到带 Pillow 的 python（不影响功能，只是没有自定义图标）" >&2
  else
    "$PY" "$ROOT/scripts/make_icon.py" "$MASTER"
    ICONSET="$ROOT/.build/AppIcon.iconset"
    rm -rf "$ICONSET"; mkdir -p "$ICONSET"
    for SZ in 16 32 128 256 512; do
      sips -z $SZ $SZ "$MASTER" --out "$ICONSET/icon_${SZ}x${SZ}.png" >/dev/null
      DBL=$((SZ * 2))
      sips -z $DBL $DBL "$MASTER" --out "$ICONSET/icon_${SZ}x${SZ}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$ICNS"
    rm -rf "$ICONSET"
  fi
fi

# ---------- 4. 组装 .app ----------
echo "=== 组装 bundle ==="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MajsoulHelper"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
[ -f "$ICNS" ] && cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"

# 牌面素材：模板匹配要用（ui.png 是图集，ui.atlas 给出每张 sprite 的坐标与 80×129 尺寸）
for f in "$ROOT/Resources/ui.png" "$ROOT/Resources/ui.atlas"; do
  [ -f "$f" ] && cp "$f" "$APP/Contents/Resources/"
done
# 菜单栏雀头图标（statusIcon 从 Bundle.main.resourceURL 加载；
# ★ 漏拷会静默走 SF Symbol 兜底——曾漏了几个月，用户看到的是「两个点」）
for f in "$ROOT/Resources/menubar.png" "$ROOT/Resources/menubar@2x.png" "$ROOT/Resources/menubar@3x.png"; do
  [ -f "$f" ] && cp "$f" "$APP/Contents/Resources/"
done
printf 'APPL????' > "$APP/Contents/PkgInfo"

# ---------- 4.5 Sparkle 框架嵌入（2026-10-16） ----------
# SPM 产物在 .build/$CONFIG/Sparkle.framework；XPC services / Autoupdate 都
# 在 framework 内部（Versions/B/Frameworks 下），一起拷即可。
SPARKLE_FW="$ROOT/.build/$CONFIG/Sparkle.framework"
if [ -d "$SPARKLE_FW" ]; then
  echo "=== 嵌入 Sparkle 框架 ==="
  mkdir -p "$APP/Contents/Frameworks"
  rm -rf "$APP/Contents/Frameworks/Sparkle.framework"
  cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/"
  # rpath：可执行文件按 @executable_path/../Frameworks 找 Sparkle
  install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$APP/Contents/MacOS/MajsoulHelper"
else
  echo "⚠️ 没找到 Sparkle.framework（$SPARKLE_FW）——更新功能将不可用" >&2
fi

# ---------- 4.6 内置识别引擎（majsoul-vision，零依赖二进制） ----------
#   发布版走这条路：PyInstaller 产物（含 Python 运行时 + OpenCV），
#   App 启动后直接执行 Contents/Resources/vision/majsoul-vision。
VISION_DIR="$ROOT/Resources/vision"
if [ ! -d "$VISION_DIR" ] && [ -d "$ROOT/../majsoul-vision/dist/majsoul-vision" ]; then
  VISION_DIR="$ROOT/../majsoul-vision/dist/majsoul-vision"
fi
if [ -d "$VISION_DIR" ]; then
  echo "=== 内置识别引擎：$VISION_DIR ==="
  rm -rf "$APP/Contents/Resources/vision"
  mkdir -p "$APP/Contents/Resources"
  cp -R "$VISION_DIR" "$APP/Contents/Resources/vision"
else
  echo "⚠️ 没有识别引擎（Resources/vision 不存在）——仅开发模式（pip 包）可用" >&2
fi

strip -x "$APP/Contents/MacOS/MajsoulHelper" 2>/dev/null || true

# ---------- 5. 签名 ----------
#
# 这里必须用**稳定的签名身份**，否则屏幕录制授权会随每次编译失效。原因见
# scripts/setup_signing.sh 开头那段长注释：ad-hoc 的 DR 是 cdhash（内容指纹），
# 编译一次变一次，对 TCC 来说就是"换了个 App"。
#
# 注意查身份时**不能加 `-v`** —— `-v` 只列"受信任"的身份，
# 而本地自签证书没有 Apple 信任链，会被 `-v` 过滤掉（显示 NOT_TRUSTED）。
# 但 TCC 认的是 Designated Requirement，不需要证书被系统信任。
KEYCHAIN="${MAJSOUL_KEYCHAIN:-$HOME/Library/Keychains/majsoulhelper-signing.keychain-db}"
identify_identity() {
  security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null \
    | grep -o '"MajsoulHelper[^"]*"' | head -1 | tr -d '"' || true
}

IDENTITY="$(identify_identity)"
if [ -z "$IDENTITY" ] && [ -x "$ROOT/scripts/setup_signing.sh" ]; then
  echo "=== 还没建签名身份，先创建（只需一次） ==="
  "$ROOT/scripts/setup_signing.sh" | tail -20
  IDENTITY="$(identify_identity)"
fi

# ★ Sparkle 嵌套组件必须 inside-out 单独签（codesign 签 .app 不会重签嵌套代码）
FW="$APP/Contents/Frameworks/Sparkle.framework"
sign_sparkle() {
  local ID="$1"
  [ -d "$FW" ] || return 0
  find "$FW/Versions/B" -type d \( -name "*.xpc" -o -name "*.app" \) -print0 2>/dev/null \
    | while IFS= read -r -d '' item; do
        codesign --force --sign "$ID" --keychain "$KEYCHAIN" "$item"
      done
  codesign --force --sign "$ID" --keychain "$KEYCHAIN" "$FW"
}

if [ -n "$IDENTITY" ]; then
  echo "=== 用稳定身份签名：$IDENTITY ==="
  security unlock-keychain -p "majsoulhelper-local-signing" "$KEYCHAIN" 2>/dev/null || true
  sign_sparkle "$IDENTITY"
  # 内置识别引擎（含大量 dylib）—— --deep 递归签它自己的嵌套
  if [ -d "$APP/Contents/Resources/vision" ]; then
    codesign --force --deep --sign "$IDENTITY" --keychain "$KEYCHAIN" \
      "$APP/Contents/Resources/vision/majsoul-vision"
  fi
  codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" --identifier "$BUNDLE_ID" "$APP"
else
  echo "=== ⚠️ 自签身份不可用，退回 Ad-hoc ==="
  echo "    ad-hoc 的 cdhash 每次编译都变，屏幕录制授权会随之失效。"
  echo "    想根治请先跑：./scripts/setup_signing.sh"
  sign_sparkle "-"
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
fi

codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/  /'

# ---------- 6. 校验签名身份形态（防止悄悄退回 ad-hoc） ----------
DR="$(codesign -d -r- "$APP" 2>&1 | grep designated || true)"
echo "  $DR"
case "$DR" in
  *certificate*)
    echo "  ✅ DR 是证书型 —— 屏幕录制授权不会因为重新编译而失效。" ;;
  *cdhash*)
    echo "  ⚠️ DR 是 cdhash 型 —— 这一版的屏幕录制授权在下次编译后会失效。" ;;
esac

echo ""
echo "✅ 完成：$APP"
echo "   启动：open \"$APP\""
echo "   无界面自测：\"$APP/Contents/MacOS/MajsoulHelper\" --selftest --list"
echo "   界面快照：  \"$APP/Contents/MacOS/MajsoulHelper\" --snapshot /tmp/ui"
