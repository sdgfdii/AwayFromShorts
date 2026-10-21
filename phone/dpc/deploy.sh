#!/usr/bin/env bash
# AwayFromShorts 一键部署（Device Owner 模式）
#
# 做的事：检查前提 → 装 APK → 设为设备所有者 → 验证
# 用法：
#   bash deploy.sh                     # 用同目录的 ../afs-guard.apk
#   bash deploy.sh /path/to/xxx.apk    # 指定 APK
#   ADB=/path/to/adb bash deploy.sh    # adb 不在 PATH 时
#
# 注意：这一步不可逆。装完「恢复出厂」会变灰，只能靠 uninstall.sh 拆。

set -uo pipefail
cd "$(dirname "$0")"

# Git Bash（MSYS）下会把 /data/local/tmp 当成 Windows 路径改写，
# 这里关掉转换；Linux / macOS 上这个变量没有副作用。
export MSYS_NO_PATHCONV=1

PKG=com.afs.guard
ADMIN=$PKG/.AfsAdmin

# ---------- adb ----------
if [ -z "${ADB:-}" ]; then
  if command -v adb >/dev/null 2>&1; then
    ADB=adb
  elif [ -n "${AFS_SDK:-}" ] && [ -x "$AFS_SDK/platform-tools/adb" ]; then
    ADB="$AFS_SDK/platform-tools/adb"
  elif [ -x "$AFS_SDK/platform-tools/adb.exe" ]; then
    ADB="$AFS_SDK/platform-tools/adb.exe"
  else
    echo "找不到 adb。装 platform-tools，或用 ADB=/path/to/adb 指定。" >&2
    exit 1
  fi
fi

APK="${1:-../afs-guard.apk}"
[ -f "$APK" ] || { echo "找不到 APK：$APK（先跑 bash build.sh）" >&2; exit 1; }

say() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
ok()  { printf '  [OK]   %s\n' "$*"; }
bad() { printf '  [XX]   %s\n' "$*"; }
warn(){ printf '  [!!]   %s\n' "$*"; }

# ---------- 1. 设备 ----------
say "1/6 检查设备"
STATE=$("$ADB" get-state 2>/dev/null)
if [ "$STATE" != "device" ]; then
  bad "没连上设备（state=${STATE:-none}）"
  echo "    1) 数据线要能传数据，不是充电线"
  echo "    2) 开发者选项 → USB 调试 打开"
  echo "    3) 手机上点「允许 USB 调试」"
  exit 1
fi
MODEL=$("$ADB" shell getprop ro.product.model 2>/dev/null | tr -d '\r')
REL=$("$ADB" shell getprop ro.build.version.release 2>/dev/null | tr -d '\r')
SDK=$("$ADB" shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r')
ok "$MODEL · Android $REL (API $SDK)"
if [ "${SDK:-0}" -lt 24 ]; then
  bad "需要 Android 7.0 (API 24) 及以上"
  exit 1
fi

# ---------- 2. 已部署过？ ----------
say "2/6 检查是否已部署"
OWN=$("$ADB" shell dpm list-owners 2>/dev/null | tr -d '\r')
if echo "$OWN" | grep -q "DeviceOwner"; then
  ok "这台设备已经是设备所有者了"
  echo "$OWN" | sed 's/^/      /'
  echo ""
  echo "  跳过用户 / 账号检查 —— 那些限制只对首次部署生效，"
  echo "  部署之后登录账号、装应用都不影响。本次只更新 APK。"
  ALREADY=1
else
  ALREADY=0

  # ---------- 3. 单用户 ----------
  say "3/6 检查用户（首次部署必须只有一个）"
  USERS=$("$ADB" shell pm list users 2>/dev/null | tr -d '\r')
  echo "$USERS" | sed 's/^/    /'
  USER_COUNT=$(echo "$USERS" | grep -c "UserInfo{" || true)
  if [ "$USER_COUNT" -gt 1 ]; then
    bad "有 $USER_COUNT 个用户，Device Owner 装不上"
    echo ""
    echo "  这是最常见的拦路虎。多出来的通常是："
    echo "    OPPO/一加 ColorOS 的「应用分身」→ 会留下 Type: profile.CLONE 的 user 999"
    echo "    小米的「手机分身 / 第二空间」"
    echo "    华为的「隐私空间」/ vivo 的「应用分身」/ 工作资料"
    echo ""
    echo "  关掉分身功能后往往仍有残留，pm remove-user / am stop-user 都删不掉。"
    echo "  唯一确定有效的办法是恢复出厂，开机向导里不要用手机搬家。"
    echo "  详见 COMPATIBILITY.md。"
    exit 1
  fi
  ok "只有一个用户"

  # ---------- 4. 账号 ----------
  say "4/6 检查账号（首次部署必须一个都没有）"
  ACCS=$("$ADB" shell dumpsys account 2>/dev/null | grep "Account {" | tr -d '\r')
  if [ -n "$ACCS" ]; then
    bad "设备上还有账号："
    echo "$ACCS" | sed 's/^/      /'
    echo ""
    echo "  Device Owner 要求设备上没有任何账号。"
    echo "  不只是 Google / 厂商账号，**任何 App 注册的账号都算**"
    echo "  （实测抖音登录后会自动注册 com.ss.android.ugc.aweme）。"
    echo "  去 设置 → 账号 里逐个退出，再回来重跑本脚本。"
    exit 1
  fi
  ok "没有账号"
fi

# ---------- 5. 安装 ----------
say "5/6 安装 APK"
# ColorOS 上 adb install 的流式安装会报 Failure [-99]，统一走 push + pm install
"$ADB" push "$APK" /data/local/tmp/awayfromshorts.apk >/dev/null 2>&1 \
  || { bad "推送失败"; exit 1; }
OUT=$("$ADB" shell pm install -r /data/local/tmp/awayfromshorts.apk 2>&1 | tr -d '\r')
echo "$OUT" | sed 's/^/    /'
if ! echo "$OUT" | grep -q "Success"; then
  bad "安装失败"
  echo "  如果报 INSTALL_FAILED_UPDATE_INCOMPATIBLE：旧版本签名不同，先卸载。"
  exit 1
fi
ok "已安装"

# pm install -r 之后 App 处于 stopped 状态，系统广播（含 MY_PACKAGE_REPLACED / BOOT_COMPLETED）
# 根本送不进去 —— 闹钟从此不排，只有手动打开 App 才会冻。这里用显式广播把它叫起来，
# 让 apply() + schedule() 立刻跑一遍（--include-stopped-packages 是关键）。
"$ADB" shell "am broadcast --include-stopped-packages -a com.afs.guard.WAKE -n com.afs.guard/.BootReceiver" >/dev/null 2>&1
sleep 2
if "$ADB" shell "dumpsys alarm" 2>/dev/null | grep -q "com.afs.guard"; then
  ok "闹钟已排上（未打开 App 也会按时冻结/放行）"
else
  warn "闹钟没排上：请手动打开一次 App"
fi

# Doze 白名单：GuardService 里的常驻 wakelock 只能挡住"灭屏 CPU 休眠"，
# 挡不住系统级 Doze —— 两个一起上才稳。加进白名单会持久化，重启也在。
"$ADB" shell "dumpsys deviceidle whitelist +$PKG" >/dev/null 2>&1
if "$ADB" shell "dumpsys deviceidle whitelist" 2>/dev/null | grep -q "$PKG"; then
  ok "已在 Doze 白名单（灭屏不会被整体冻结）"
else
  warn "没能加入 Doze 白名单，灭屏后可能被冻结"
fi

# 常驻 wakelock 是 v1.8.0 才有的，这里确认它真的持上了
if "$ADB" shell "dumpsys power" 2>/dev/null | grep -q "afs:guard"; then
  ok "常驻 wakelock 已持有（30s 节拍不会停）"
else
  warn "wakelock 没持上：确认 APK 是 1.8.0+，服务在跑（dumpsys power | grep afs:guard）"
fi

# ---------- 6. 设为设备所有者 ----------
say "6/6 设为设备所有者"
if [ "${ALREADY:-0}" = "1" ]; then
  ok "已部署，跳过"
  exit 0
fi
OUT=$("$ADB" shell dpm set-device-owner "$ADMIN" 2>&1 | tr -d '\r')
echo "$OUT" | sed 's/^/    /'
OWN=$("$ADB" shell dpm list-owners 2>/dev/null | tr -d '\r')
if echo "$OWN" | grep -q "DeviceOwner"; then
  ok "成功"
  echo "$OWN" | sed 's/^/      /'
  echo ""
  echo "  下一步：在手机上打开 AwayFromShorts，有 10 分钟配置宽限，"
  echo "  把放行星期、时段、要冻结的 App 设好，点「立即应用」。"
  echo ""
  echo "  ⚠ 之后「恢复出厂设置」会被禁用。要拆只有一条路："
  echo "     bash uninstall.sh"
else
  bad "设置失败"
  echo "  常见原因按出现频率排序："
  echo "    · 还有账号没退干净（含 App 账号）"
  echo "    · 有应用分身 / 第二空间 / 隐私空间残留的多用户"
  echo "    · 设备上已经有别的 Device Owner 或工作资料"
  echo "    · 部分厂商 ROM 移除了 DPC 支持"
  exit 1
fi
