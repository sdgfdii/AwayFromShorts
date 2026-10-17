#!/data/data/com.termux/files/usr/bin/sh
# Termux:Boot 入口。install.sh 会把它复制到 ~/.termux/boot/afs-phone.sh
termux-wake-lock 2>/dev/null || true
pkill -f 'afs-phone/guard.sh' 2>/dev/null || true
nohup "$HOME/afs-phone/guard.sh" run >> "$HOME/afs-phone/boot.log" 2>&1 &
