#!/bin/bash
# 建一张本地自签代码签名证书，让 App 的签名身份**跨编译保持不变**。
#
# ── 为什么需要它 ────────────────────────────────────────────────────────
# ad-hoc 签名（`codesign --sign -`）的 Designated Requirement 是
#     designated => cdhash H"xxxx"
# 也就是「二进制内容的指纹」。每次重新编译 cdhash 都变，于是对 macOS 来说
# 这就是**另一个 App**。屏幕录制这类 TCC 授权是按这个身份记账的，所以会出现：
#   · 系统设置里按名字还记得旧记录，显示「已授权」
#   · 但当前二进制对不上任何记录 → 一律拒绝
#   · 反复开关那个开关也没用（它改的是那条对不上的旧记录）
#
# 换成自签证书后，Designated Requirement 变成
#     designated => identifier "com.feng.majsoulhelper" and certificate root = H"yyyy"
# 只要 bundle id 和证书不变，重编多少次身份都不变 —— 授权只需要给一次。
#
# ── 两个实测踩到的坑（脚本里已经绕开）────────────────────────────────────
# 1. `openssl pkcs12 -export` 出来的 p12，**macOS 的 `security import` 导不进**：
#    "MAC verification failed during PKCS12 import (wrong password?)"。
#    LibreSSL 3.3 默认用的其实已经是老算法（RC2-40 / 3DES / SHA1 MAC），照样失败。
#    → 改成把**证书和私钥分开导入**（`security import cert.pem` / `key.pem`）。
# 2. 导入后如果只设了 ACL 没设 partition list，**每次 codesign 都会弹密码框**，
#    构建脚本会卡在那里等点击。→ 必须补 `security set-key-partition-list`。
#
# ── 说明 ──────────────────────────────────────────────────────────────
# · 证书放在**独立钥匙串**里，不碰你 login 钥匙串里的任何东西。
# · 钥匙串密码固定写在下面：它保护的是"一张只能给本机 App 签名的自签证书"，
#   不是机密；写出来是为了让构建脚本能非交互解锁（否则每次编译弹密码框）。
# · 证书只在本机有效，无法冒充任何其它 App（没有 Apple 的信任链背书）。
set -euo pipefail

KEYCHAIN="${MAJSOUL_KEYCHAIN:-$HOME/Library/Keychains/majsoulhelper-signing.keychain-db}"
KC_PASS="majsoulhelper-local-signing"
CERT_CN="MajsoulHelper Local Dev"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "=== 本地自签代码签名证书 ==="
echo "钥匙串: $KEYCHAIN"
echo "证书名: $CERT_CN"
echo

# ── 幂等：已经有就只确保可用 ──
if security find-certificate -c "$CERT_CN" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "证书已存在。"
else
  echo "--- 1/4 生成密钥与自签证书 ---"
  cat > "$TMP/ossl.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no

[dn]
CN = MajsoulHelper Local Dev
O = MajsoulHelper
C = CN

[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF
  openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -config "$TMP/ossl.cnf" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" >/dev/null 2>&1

  echo "--- 2/4 建独立钥匙串 ---"
  [ -f "$KEYCHAIN" ] || security create-keychain -p "$KC_PASS" "$KEYCHAIN"
  security set-keychain-settings -lut 86400 "$KEYCHAIN"   # 关掉自动锁定
  security unlock-keychain -p "$KC_PASS" "$KEYCHAIN"

  echo "--- 3/4 分开导入证书与私钥（-A = 允许任何程序使用，避免每次弹框）---"
  security import "$TMP/cert.pem" -k "$KEYCHAIN" -A
  security import "$TMP/key.pem"  -k "$KEYCHAIN" -A
fi

# ── 每次都要确保：解锁 + partition list ──
security unlock-keychain -p "$KC_PASS" "$KEYCHAIN"
echo "--- 4/4 设置 partition list（缺这一步 codesign 每次都会弹密码框）---"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PASS" "$KEYCHAIN" >/dev/null 2>&1 \
  && echo "  partition list OK" \
  || echo "  ⚠️ partition list 设置失败，首次签名可能弹一次授权框（点「始终允许」即可）"

echo
echo "=== 身份 ==="
security find-identity -p codesigning "$KEYCHAIN" 2>&1 | sed -n '1,6p'
echo "（显示 NOT_TRUSTED 是正常的：自签证书没有 Apple 信任链。TCC 认的是"
echo "  Designated Requirement，不需要这张证书被系统信任。）"
echo

# ── 真签一次做冒烟测试，并验证 DR 是"证书型"而不是"cdhash 型" ──
echo "=== 冒烟测试：能不能真的签，DR 是不是稳定的 ==="
SMOKE="$TMP/smoke.bin"; echo smoke > "$SMOKE"
if codesign --force --sign "$CERT_CN" --keychain "$KEYCHAIN" --identifier com.feng.majsoulhelper.smoke "$SMOKE" 2>/dev/null; then
  DR="$(codesign -d -r- "$SMOKE" 2>&1 | grep designated || true)"
  echo "$DR"
  case "$DR" in
    *certificate*) echo "✅ DR 是证书型 —— 重新编译不会改变签名身份，授权只需给一次。" ;;
    *cdhash*)      echo "⚠️ DR 仍是 cdhash 型，TCC 授权还是会随编译失效，请检查签名步骤。" ;;
    *)             echo "⚠️ 未能识别 DR 形态，请人工看一下上面的输出。" ;;
  esac
else
  echo "❌ 签名失败。若屏幕上弹了钥匙串授权框，请点「始终允许」后重跑本脚本。"
  exit 1
fi

echo
echo "完成。接下来运行 ./scripts/build_app.sh 即会用这个身份签名。"
