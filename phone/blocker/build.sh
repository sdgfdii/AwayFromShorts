#!/usr/bin/env bash
# 手工构建 AFS 守卫（无障碍版）—— 不依赖 Gradle，只用 SDK 里的 aapt2 / d8 / apksigner。
# 用法（Git Bash）：  bash build.sh
set -euo pipefail

cd "$(dirname "$0")"

# ---------- 环境 ----------
SDK="${AFS_SDK:-C:/Users/nj/.afs-android/sdk}"
BT="$SDK/build-tools/34.0.0"
ANDROID_JAR="$SDK/platforms/android-34/android.jar"

if [ ! -f "$BT/aapt2.exe" ]; then
  echo "找不到 build-tools：$BT" >&2
  echo "用 AFS_SDK=/你的/sdk 覆盖。" >&2
  exit 1
fi
if [ ! -f "$ANDROID_JAR" ]; then
  echo "找不到 android.jar：$ANDROID_JAR" >&2
  exit 1
fi

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
"$BT/aapt2.exe" compile --dir res -o "$OUT/flat"

# ---------- 2. 链接资源 ----------
echo "[2/6] aapt2 link"
"$BT/aapt2.exe" link \
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
"$BT/d8.bat" --lib "$ANDROID_JAR" --min-api 24 --output "$OUT/dex" \
  "$OUT/classes.jar" libs/*.jar

# ---------- 5. 打包 + 对齐 ----------
echo "[5/6] zip + zipalign"
cp "$OUT/base.apk" "$OUT/unsigned.apk"
if command -v zip >/dev/null 2>&1; then
  ( cd "$OUT" && zip -q -j unsigned.apk dex/classes.dex )
else
  PY="${AFS_PYTHON:-C:/Users/nj/.workbuddy/binaries/python/versions/3.13.12/python.exe}"
  [ -x "$PY" ] || PY="$(command -v python3 || command -v python)"
  "$PY" - "$OUT/unsigned.apk" "$OUT/dex/classes.dex" <<'PYEOF'
import sys, zipfile
apk, dex = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(apk, "a", zipfile.ZIP_DEFLATED) as z:
    z.write(dex, "classes.dex")
PYEOF
fi
"$BT/zipalign.exe" -f -p 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"

# ---------- 6. 签名 ----------
echo "[6/6] apksigner"
# 与 DO 版共用同一把 key，方便统一管理
KS="../dpc/keystore/afs.keystore"
if [ ! -f "$KS" ]; then
  echo "找不到签名库 $KS" >&2
  exit 1
fi
"$BT/apksigner.bat" sign \
  --ks "$KS" --ks-pass pass:afsguard --key-pass pass:afsguard \
  --min-sdk-version 24 \
  --v1-signing-enabled true --v2-signing-enabled true --v3-signing-enabled true \
  --out "$OUT/afs-blocker.apk" "$OUT/aligned.apk"

"$BT/apksigner.bat" verify --min-sdk-version 24 "$OUT/afs-blocker.apk"
rm -f "$OUT/afs-blocker.apk.idsig"
cp -f "$OUT/afs-blocker.apk" ../afs-blocker.apk

echo
echo "完成："
ls -l ../afs-blocker.apk
