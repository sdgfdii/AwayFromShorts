#!/data/data/com.termux/files/usr/bin/bash
# AFS Phone Guard —— 到点直接把抖音「禁用」，不走系统「屏幕限时」
#
# 用法:
#   ./guard.sh run      常驻轮询(默认)
#   ./guard.sh once     只跑一轮(给 termux-job-scheduler 用)
#   ./guard.sh status   看当前状态
#   ./guard.sh allow    强制放行(想刷的时候)
#   ./guard.sh block    强制禁用
#
# 依赖: Shizuku 在跑 + rish 放在 $HOME (chmod +x)

set -u

DIR="$HOME/afs-phone"
mkdir -p "$DIR"

# ---------------- 配置 ----------------
ALLOW_START="2000"     # 每天放行开始 HHMM
ALLOW_END="2300"       # 每天放行结束 HHMM
INTERVAL=60            # 轮询间隔(秒)

PACKAGES=(
  "com.ss.android.ugc.aweme"        # 抖音
  "com.ss.android.ugc.aweme.lite"   # 抖音极速版
  "com.ss.android.ugc.live"         # 抖音火山版
)

RISH="$HOME/rish"
LOG="$DIR/guard.log"
# --------------------------------------

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"
  if [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 200000 ]; then
    mv -f "$LOG" "$LOG.1" 2>/dev/null
    log "log rotated"
  fi
}

shq() {
  # 通过 Shizuku 以 shell 身份执行
  "$RISH" -c "$1" 2>/dev/null
}

preflight() {
  if [ ! -x "$RISH" ]; then
    log "FATAL rish 不存在或不可执行: $RISH"
    echo "缺少 rish。按 Shizuku 的「Use rish」页面把 rish 与 rish_shizuku.dex 放到 $HOME 并 chmod +x rish"
    exit 2
  fi
  if ! shq "id" | grep -q "uid=2000"; then
    log "FATAL Shizuku 未运行(rish 拿不到 shell)"
    echo "Shizuku 没在跑。去 Shizuku App 里用「无线调试」启动它。"
    exit 3
  fi
}

is_installed() {
  shq "pm list packages $1" | grep -qx "package:$1"
}

is_disabled() {
  shq "pm list packages -d" | grep -qx "package:$1"
}

do_block() {
  local pkg="$1" changed=0
  is_installed "$pkg" || return 0
  if ! is_disabled "$pkg"; then
    shq "pm disable-user --user 0 $pkg" >/dev/null
    changed=1
  fi
  shq "am force-stop $pkg" >/dev/null
  [ "$changed" = "1" ] && log "block  $pkg"
  return 0
}

do_allow() {
  local pkg="$1"
  is_installed "$pkg" || return 0
  if is_disabled "$pkg"; then
    shq "pm enable $pkg" >/dev/null
    log "allow  $pkg"
  fi
  return 0
}

in_window() {
  local now start end
  now=$((10#$(date +%H%M)))
  start=$((10#$ALLOW_START))
  end=$((10#$ALLOW_END))
  if [ "$start" -le "$end" ]; then
    [ "$now" -ge "$start" ] && [ "$now" -lt "$end" ]
  else
    # 跨午夜窗口
    [ "$now" -ge "$start" ] || [ "$now" -lt "$end" ]
  fi
}

tick() {
  local pkg
  if in_window; then
    for pkg in "${PACKAGES[@]}"; do do_allow "$pkg"; done
  else
    for pkg in "${PACKAGES[@]}"; do do_block "$pkg"; done
  fi
}

cmd="${1:-run}"

case "$cmd" in
  status)
    preflight
    echo "时间: $(date '+%H:%M:%S')  窗口: $ALLOW_START-$ALLOW_END  当前: $(in_window && echo 放行 || echo 禁用)"
    for pkg in "${PACKAGES[@]}"; do
      if ! is_installed "$pkg"; then
        echo "  $pkg  未安装"
      elif is_disabled "$pkg"; then
        echo "  $pkg  已禁用"
      else
        echo "  $pkg  可用"
      fi
    done
    ;;
  allow)
    preflight
    for pkg in "${PACKAGES[@]}"; do do_allow "$pkg"; done
    log "manual allow"
    echo "已放行"
    ;;
  block)
    preflight
    for pkg in "${PACKAGES[@]}"; do do_block "$pkg"; done
    log "manual block"
    echo "已禁用"
    ;;
  once)
    preflight
    tick
    ;;
  run)
    preflight
    log "guard start (window $ALLOW_START-$ALLOW_END)"
    trap 'log "guard stop"; exit 0' INT TERM
    while true; do
      tick
      sleep "$INTERVAL"
    done
    ;;
  *)
    echo "用法: $0 [run|once|status|allow|block]"
    exit 1
    ;;
esac
