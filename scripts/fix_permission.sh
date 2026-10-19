#!/bin/bash
# 清掉本 App 在系统里的屏幕录制授权记录，然后引导重新授权。
#
# 什么时候需要它：
#   系统设置 → 录屏与系统录音 里**显示已经授权了**，但 App 就是截不到图，
#   反复开关那个开关也没用。
#
# 为什么会出现：
#   TCC（系统的权限数据库）按**代码签名身份**记账。用 ad-hoc 签名时，
#   Designated Requirement 是 `cdhash`，也就是二进制内容的指纹 ——
#   改一次代码重新编译，cdhash 就变，系统眼里的"这个 App"就换了一个。
#   于是系统设置里显示的"已授权"属于**上一个编译版本**，
#   当前这一版对不上它；反复开关只是在改那条对不上的旧记录。
#
#   根治办法是让签名身份跨编译稳定（见 scripts/setup_signing.sh），
#   本脚本只负责把已经脏掉的旧记录清掉、让系统重新登记一次。
#
# 注意：必须带 bundle id。`tccutil reset ScreenCapture` 不带 id
# 会清掉**所有** App 的屏幕录制授权，那是破坏性的。
set -euo pipefail

BUNDLE_ID="${1:-com.feng.majsoulhelper}"
APP="$HOME/Developer/majsoul-helper/dist/MajsoulHelper.app"

echo "=== 重置 $BUNDLE_ID 的屏幕录制授权记录 ==="

# 正在运行的 App 会持有 TCC 的进程内缓存，先退掉
if pgrep -f "MajsoulHelper.app" >/dev/null 2>&1; then
  echo "先退出正在运行的 App…"
  pkill -f "MajsoulHelper.app" || true
  sleep 1
fi

/usr/bin/tccutil reset ScreenCapture "$BUNDLE_ID"
echo

echo "=== 下一步（必须两步都做，顺序不能反）==="
echo "1) 打开：系统设置 → 隐私与安全性 → 录屏与系统录音"
echo "   把「雀魂助手」重新勾上（如果它还列着，先取消再勾；不在了就等下一条）"
echo "2) 重新启动 App：open \"$APP\""
echo "   启动后 App 会自己申请一次，系统设置里会重新出现这一项，勾上即可。"
echo
echo "重新打开 App 后，面板上的权限提示条会自己消失，就可以开始分析牌局了。"
