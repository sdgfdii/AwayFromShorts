#!/data/data/com.termux/files/usr/bin/bash
# 在 Termux 里执行: bash install.sh
set -eu

SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/afs-phone"

mkdir -p "$DEST" "$HOME/.termux/boot"

cp -f "$SRC/guard.sh" "$DEST/guard.sh"
cp -f "$SRC/boot.sh"  "$DEST/boot.sh"
chmod +x "$DEST/guard.sh" "$DEST/boot.sh"

cp -f "$DEST/boot.sh" "$HOME/.termux/boot/afs-phone.sh"
chmod +x "$HOME/.termux/boot/afs-phone.sh"

# 每 15 分钟兜底一轮(常驻进程被系统杀掉后还能拉回来)
termux-job-scheduler \
  --script "$DEST/guard.sh" \
  --script-arguments once \
  --period-ms 900000 \
  --persisted true 2>/dev/null || echo "termux-job-scheduler 不可用(可忽略, 靠 Termux:Boot 兜底)"

echo "装好了 -> $DEST"
echo "下一步: ./guard.sh status"
