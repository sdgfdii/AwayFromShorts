#!/usr/bin/env bash
# 离线回归：不连手机、不需要 Android 运行时。
# 用法（Git Bash）：  bash test/run.sh
set -euo pipefail
cd "$(dirname "$0")/.."

SDK="${AFS_SDK:-C:/Users/nj/.afs-android/sdk}"
ANDROID_JAR="$SDK/platforms/android-34/android.jar"
[ -f "$ANDROID_JAR" ] || { echo "找不到 $ANDROID_JAR" >&2; exit 1; }

if [ -z "${JAVA_HOME:-}" ]; then
  JAVA_HOME="$(dirname "$(dirname "$(command -v javac)")")"
  export JAVA_HOME
fi
JAVAC="$JAVA_HOME/bin/javac"
JAVA="$JAVA_HOME/bin/java"
[ -f "$JAVAC" ] || JAVAC=javac
[ -f "$JAVA" ] || JAVA=java

SEP=";"
case "$(uname -s)" in
  Linux|Darwin) SEP=":" ;;
esac

build_run() {
  local src="$1"
  local name="$2"
  local out="build/test/$name"
  rm -rf "$out"
  mkdir -p "$out"
  find "$src" test/java -name '*.java' > "$out/sources.txt"
  "$JAVAC" -encoding UTF-8 -nowarn -source 8 -target 8 \
    -bootclasspath "$ANDROID_JAR" -classpath "$ANDROID_JAR" \
    -d "$out" @"$out/sources.txt" 2>&1 | grep -vE '^(warning|注意|Note)' || true
  "$JAVA" -Dfile.encoding=UTF-8 -Dstdout.encoding=UTF-8 -Dstderr.encoding=UTF-8 \
    -cp "$ANDROID_JAR${SEP}$out" com.afs.blocker.GuardTest
}

echo "################ A) 默认窗口 20:00 -> 23:00 ################"
build_run "java" "default"

echo
echo "################ B) 跨午夜窗口 23:00 -> 20:00 ################"
rm -rf build/test/cross-src
cp -r java build/test/cross-src
sed -i 's/ALLOW_START_H = 20;/ALLOW_START_H = 23;/' build/test/cross-src/com/afs/blocker/Guard.java
sed -i 's/ALLOW_END_H   = 23;/ALLOW_END_H   = 20;/' build/test/cross-src/com/afs/blocker/Guard.java
grep -n "ALLOW_START_H\|ALLOW_END_H" build/test/cross-src/com/afs/blocker/Guard.java | head -2
build_run "build/test/cross-src" "cross"
