#!/bin/bash
# 发布 MajsoulHelper（Sparkle 更新链）。
#
# 用法：
#   ./scripts/release.sh 0.2.0            # 正常发布（build 号自动 +1）
#   ./scripts/release.sh 0.2.0 --no-build # 跳过重新构建（dist/ 已是最新）
#
# 脚本做：写版本号 → 构建 → zip → EdDSA 签名 → 生成 appcast.xml，
# 产物落在 dist/release/。★ **不推送 GitHub**——上传动作留给维护者手动：
#   1. GitHub 网页 New Release，tag 填 <版本号>（如 0.2.0）
#   2. 上传 dist/release/MajsoulHelper-<版本号>.zip 和 appcast.xml
#   3. appcast.xml 还要放到仓库 main 分支根目录（SUFeedURL 指向
#      raw.githubusercontent.com/sdtafxy/majsoul-helper/main/appcast.xml）
#
# 前提（一次性）：
#   - ~/.developer/sparkle-bin/bin/ 有 sign_update / generate_appcast
#     （Sparkle release 归档的 bin/，见 docs/更新发布.md）
#   - 私钥在登录 keychain（generate_keys 时自动存入；备份在
#     ~/.majsoul-sparkle-private-key.txt，600，**绝不进 git**）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-}"
[ -n "$VERSION" ] || { echo "用法: $0 <版本号> [--no-build]" >&2; exit 1; }
NO_BUILD=0
[ "${2:-}" = "--no-build" ] && NO_BUILD=1

SPARKLE_BIN="$HOME/.developer/sparkle-bin/bin"
INFO="$ROOT/Resources/Info.plist"
APP="$ROOT/dist/MajsoulHelper.app"
REL="$ROOT/dist/release"

# ---------- 1. 版本号（shortVersion = 入参，build = 当前 +1） ----------
CUR_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO")"
NEW_BUILD=$((CUR_BUILD + 1))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$INFO"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" "$INFO"
echo "=== 版本：$VERSION（build $CUR_BUILD → $NEW_BUILD） ==="

# ---------- 2. 构建 ----------
if [ "$NO_BUILD" = "0" ]; then
  bash scripts/build_app.sh
fi

# ---------- 3. 打包 ----------
mkdir -p "$REL"
ZIP="$REL/MajsoulHelper-$VERSION.zip"
rm -f "$ZIP"
(cd dist && zip -qr "$(basename "$ZIP")" MajsoulHelper.app)
echo "=== 打包：$ZIP ==="

# ---------- 4. EdDSA 签名（私钥读 keychain） ----------
[ -x "$SPARKLE_BIN/sign_update" ] || { echo "缺 sign_update（$SPARKLE_BIN）" >&2; exit 1; }
echo "=== 签名 ==="
"$SPARKLE_BIN/sign_update" "$ZIP"

# ---------- 5. 生成 appcast ----------
[ -x "$SPARKLE_BIN/generate_appcast" ] || { echo "缺 generate_appcast（$SPARKLE_BIN）" >&2; exit 1; }
# generate_appcast 扫目录里的 zip；enclosure URL 默认按仓库路径猜，
# 与 Info.plist 的 SUFeedURL 约定一致（main 分支根目录）。
(cd "$REL" && "$SPARKLE_BIN/generate_appcast" .)
# 正式分发：enclosure 指向 GitHub Release 资产（generate_appcast 默认猜 raw 路径）
RELEASE_URL="https://github.com/sdtafxy/majsoul-helper/releases/download/v$VERSION/MajsoulHelper-$VERSION.zip"
/usr/bin/sed -i '' "s#https://raw.githubusercontent.com/sdtafxy/majsoul-helper/main/MajsoulHelper-$VERSION.zip#$RELEASE_URL#" "$REL/appcast.xml"
echo "  enclosure → $RELEASE_URL"
echo "=== appcast：$REL/appcast.xml ==="

cat <<EOF

完成。接下来手动：
  1. git commit -am "release $VERSION" && git tag $VERSION && git push --tags
  2. GitHub New Release（tag=$VERSION）上传：
       - MajsoulHelper-$VERSION.zip
       - appcast.xml
  3. 把 appcast.xml 提交到仓库 main 分支根目录（覆盖旧文件）并 push
     ——SUFeedURL 指向 raw.githubusercontent.com 的这份
  4. 已安装旧版本的 app 会在 24 小时内自动检查到；用户也可菜单栏
     「检查更新…」立即生效

EOF
