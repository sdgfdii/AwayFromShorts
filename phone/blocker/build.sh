#!/usr/bin/env bash
# 手工构建 AFS 守卫（无障碍版）—— 不依赖 Gradle，只用 SDK 里的 aapt2 / d8 / apksigner。
# 用法（Git Bash）：  bash build.sh
set -euo pipefail

cd "$(dirname "$0")"

# ---------- 环境（自动探测，别人的机器也能直接跑）----------
find_sdk() {
  local c
  for c in "${AFS_SDK:-}" "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" \
           "$HOME/AppData/Local/Android/Sdk" "$HOME/Android/Sdk" \
           "$HOME/Library/Android/sdk" "/usr/lib/android-sdk"; do
    [ -n "$c" ] && [ -d "$c/platforms" ] && { echo "$c"; return 0; }
  done
  return 0
}
SDK="$(find_sdk || true)"
if [ -z "$SDK" ]; then
  echo "找不到 Android SDK。装一个，或设 AFS_SDK=/你的/sdk（也可用 ANDROID_HOME）。" >&2
  echo "只需要 build-tools 34 和 platforms/android-34。" >&2
  exit 1
fi

BT="$(ls -d "$SDK"/build-tools/*/ 2>/dev/null | sort -V | tail -1 || true)"
BT="${BT%/}"
[ -n "$BT" ] || { echo "找不到 build-tools：$SDK/build-tools" >&2; exit 1; }

ANDROID_JAR="$SDK/platforms/android-34/android.jar"
[ -f "$ANDROID_JAR" ] || { echo "找不到 android.jar：$ANDROID_JAR" >&2; exit 1; }

# Windows 上是 aapt2.exe / d8.bat / apksigner.bat，Unix 上无后缀
tool() {
  local e
  for e in .exe .bat ""; do
    [ -f "$BT/$1$e" ] && { echo "$BT/$1$e"; return 0; }
  done
  echo "$BT/$1"
}
AAPT2="$(tool aapt2)"
D8="$(tool d8)"
ZIPALIGN="$(tool zipalign)"
APKSIGNER="$(tool apksigner)"

if [ -z "${JAVA_HOME:-}" ]; then
  JAVA_HOME="$(dirname "$(dirname "$(command -v javac)")")"
  export JAVA_HOME
fi
JAR="$JAVA_HOME/bin/jar.exe"
[ -f "$JAR" ] || JAR="$JAVA_HOME/bin/jar"

OUT="build"
rm -rf "$OUT"
mkdir -p "$OUT/flat" "$OUT/gen" "$OUT/classes" "$OUT/dex"

# ---------- 1. 编译资源 ----------
echo "[1/6] aapt2 compile"
"$AAPT2" compile --dir res -o "$OUT/flat"

# ---------- 2. 链接资源 ----------
echo "[2/6] aapt2 link"
"$AAPT2" link \
  -o "$OUT/base.apk" \
  -I "$ANDROID_JAR" \
  --manifest AndroidManifest.xml \
  --java "$OUT/gen" \
  --min-sdk-version 24 \
  --target-sdk-version 34 \
  --version-code 1 \
  --version-name 1.0 \
  "$OUT"/flat/*.flat

# ---------- 3. 编译 Java ----------
echo "[3/6] javac"
LIBS="$(ls libs/*.jar | tr '\n' ';' | sed 's/;$//')"
CP="$ANDROID_JAR;$LIBS"
find java "$OUT/gen" -name '*.java' > "$OUT/sources.txt"
javac -encoding UTF-8 -nowarn -source 8 -target 8 \
  -bootclasspath "$ANDROID_JAR" -classpath "$CP" \
  -d "$OUT/classes" @"$OUT/sources.txt" 2>&1 | grep -v '^warning:' || true

# ---------- 4. dex ----------
echo "[4/6] d8"
"$JAR" cf "$OUT/classes.jar" -C "$OUT/classes" .
"$D8" --lib "$ANDROID_JAR" --min-api 24 --output "$OUT/dex" \
  "$OUT/classes.jar" libs/*.jar

# ---------- 5. 打包 + 对齐 ----------
echo "[5/6] zip + zipalign"
cp "$OUT/base.apk" "$OUT/unsigned.apk"
if command -v zip >/dev/null 2>&1; then
  ( cd "$OUT" && zip -q -j unsigned.apk dex/classes.dex )
else
  PY="${AFS_PYTHON:-$(command -v python3 || command -v python || true)}"
  [ -x "$PY" ] || PY="$(command -v python3 || command -v python)"
  "$PY" - "$OUT/unsigned.apk" "$OUT/dex/classes.dex" <<'PYEOF'
import sys, zipfile
apk, dex = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(apk, "a", zipfile.ZIP_DEFLATED) as z:
    z.write(dex, "classes.dex")
PYEOF
fi
"$ZIPALIGN" -f -p 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"

# ---------- 6. 签名 ----------
echo "[6/6] apksigner"
# 与 DO 版共用同一把 key，方便统一管理
KS="../dpc/keystore/afs.keystore"
if [ ! -f "$KS" ]; then
  echo "找不到签名库 $KS" >&2
  exit 1
fi
"$APKSIGNER" sign \
  --ks "$KS" --ks-pass pass:afsguard --key-pass pass:afsguard \
  --min-sdk-version 24 \
  --v1-signing-enabled true --v2-signing-enabled true --v3-signing-enabled true \
  --out "$OUT/afs-blocker.apk" "$OUT/aligned.apk"

"$APKSIGNER" verify --min-sdk-version 24 "$OUT/afs-blocker.apk"
rm -f "$OUT/afs-blocker.apk.idsig"
cp -f "$OUT/afs-blocker.apk" ../afs-blocker.apk

echo
echo "完成："
ls -l ../afs-blocker.apk
