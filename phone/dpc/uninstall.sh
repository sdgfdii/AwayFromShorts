#!/usr/bin/env bash
# 拆除 Device Owner（这是唯一的逃生口）
#
# 用法：bash uninstall.sh
#       ADB=/path/to/adb bash uninstall.sh

set -uo pipefail
cd "$(dirname "$0")"

# Git Bash（MSYS）下会把 /data/local/tmp 当成 Windows 路径改写，
# 这里关掉转换；Linux / macOS 上这个变量没有副作用。
export MSYS_NO_PATHCONV=1

PKG=com.afs.guard
ADMIN=$PKG/.AfsAdmin

if [ -z "${ADB:-}" ]; then
  if command -v adb >/dev/null 2>&1; then
    ADB=adb
  elif [ -n "${AFS_SDK:-}" ] && [ -f "$AFS_SDK/platform-tools/adb.exe" ]; then
    ADB="$AFS_SDK/platform-tools/adb.exe"
  elif [ -x "$AFS_SDK/platform-tools/adb" ]; then
    ADB="$AFS_SDK/platform-tools/adb"
  else
    echo "找不到 adb。" >&2
    exit 1
  fi
fi

STATE=$("$ADB" get-state 2>/dev/null)
[ "$STATE" = "device" ] || { echo "设备没连上。" >&2; exit 1; }

echo "== 解除设备所有者 =="
"$ADB" shell dpm remove-active-admin "$ADMIN" 2>&1 | sed 's/^/  /'

echo "== 卸载 =="
"$ADB" uninstall "$PKG" 2>&1 | sed 's/^/  /'

echo
echo "完成。现在恢复出厂、卸载、改时间都解锁了。"
echo "想装回来：bash deploy.sh"
